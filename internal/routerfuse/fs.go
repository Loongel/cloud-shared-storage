package routerfuse

import (
	"context"
	"os"
	"path/filepath"
	"syscall"

	"cs-storage/internal/router"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
	"golang.org/x/sys/unix"
)

type Root struct {
	fs.Inode
	LiteFSRoot  string
	GlusterRoot string
	Router      *router.Router
}

type node struct {
	fs.Inode
	root *Root
	rel  string
}

func NewRoot(litefsRoot, glusterRoot string) (*Root, error) {
	for _, path := range []string{litefsRoot, glusterRoot} {
		if st, err := os.Stat(path); err != nil {
			return nil, err
		} else if !st.IsDir() {
			return nil, syscall.ENOTDIR
		}
	}
	return &Root{LiteFSRoot: litefsRoot, GlusterRoot: glusterRoot, Router: router.New()}, nil
}

func (r *Root) node(rel string) *node {
	return &node{root: r, rel: filepath.Clean("/" + rel)}
}

func (r *Root) backing(rel string) string {
	clean := filepath.Clean("/" + rel)
	if r.Router.Route(clean) == router.EngineLiteFS {
		return filepath.Join(r.LiteFSRoot, clean)
	}
	return filepath.Join(r.GlusterRoot, clean)
}

func (r *Root) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	rel := filepath.Clean("/" + name)
	p := r.backing(rel)
	st := syscall.Stat_t{}
	if err := syscall.Lstat(p, &st); err != nil {
		return nil, fs.ToErrno(err)
	}
	out.Attr.FromStat(&st)
	return r.NewInode(ctx, &node{root: r, rel: rel}, stableAttr(&st)), 0
}

func (r *Root) Getattr(ctx context.Context, f fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	return r.node("/").Getattr(ctx, f, out)
}

func (r *Root) Readdir(ctx context.Context) (fs.DirStream, syscall.Errno) {
	return r.node("/").Readdir(ctx)
}

func (r *Root) Mkdir(ctx context.Context, name string, mode uint32, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	rel := filepath.Clean("/" + name)
	p := r.backing(rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return nil, fs.ToErrno(err)
	}
	if err := os.Mkdir(p, os.FileMode(mode)); err != nil {
		return nil, fs.ToErrno(err)
	}
	st := syscall.Stat_t{}
	if err := syscall.Lstat(p, &st); err != nil {
		_ = syscall.Rmdir(p)
		return nil, fs.ToErrno(err)
	}
	out.Attr.FromStat(&st)
	return r.NewInode(ctx, &node{root: r, rel: rel}, stableAttr(&st)), 0
}

func (r *Root) Create(ctx context.Context, name string, flags uint32, mode uint32, out *fuse.EntryOut) (*fs.Inode, fs.FileHandle, uint32, syscall.Errno) {
	rel := filepath.Clean("/" + name)
	p := r.backing(rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return nil, nil, 0, fs.ToErrno(err)
	}
	fd, err := syscall.Open(p, int(flags&^syscall.O_APPEND)|os.O_CREATE, mode)
	if err != nil {
		return nil, nil, 0, fs.ToErrno(err)
	}
	st := syscall.Stat_t{}
	if err := syscall.Fstat(fd, &st); err != nil {
		_ = syscall.Close(fd)
		return nil, nil, 0, fs.ToErrno(err)
	}
	out.Attr.FromStat(&st)
	return r.NewInode(ctx, &node{root: r, rel: rel}, stableAttr(&st)), fs.NewLoopbackFile(fd), 0, 0
}

func (r *Root) Open(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	return r.node("/").Open(ctx, flags)
}

func (r *Root) OpendirHandle(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	return r.node("/").OpendirHandle(ctx, flags)
}

func (r *Root) Setattr(ctx context.Context, f fs.FileHandle, in *fuse.SetAttrIn, out *fuse.AttrOut) syscall.Errno {
	return r.node("/").Setattr(ctx, f, in, out)
}

func (r *Root) Symlink(ctx context.Context, target, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	rel := filepath.Clean("/" + name)
	st, errno := r.symlink(target, rel)
	if errno != 0 {
		return nil, errno
	}
	out.Attr.FromStat(st)
	return r.NewInode(ctx, &node{root: r, rel: rel}, stableAttr(st)), 0
}

func (r *Root) Link(ctx context.Context, target fs.InodeEmbedder, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	rel := filepath.Clean("/" + name)
	st, errno := r.link(target, rel)
	if errno != 0 {
		return nil, errno
	}
	out.Attr.FromStat(st)
	return r.NewInode(ctx, &node{root: r, rel: rel}, stableAttr(st)), 0
}

func (r *Root) symlink(target, rel string) (*syscall.Stat_t, syscall.Errno) {
	p := r.backing(rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return nil, fs.ToErrno(err)
	}
	if err := syscall.Symlink(target, p); err != nil {
		return nil, fs.ToErrno(err)
	}
	st := syscall.Stat_t{}
	if err := syscall.Lstat(p, &st); err != nil {
		_ = syscall.Unlink(p)
		return nil, fs.ToErrno(err)
	}
	return &st, 0
}

func (r *Root) link(target fs.InodeEmbedder, rel string) (*syscall.Stat_t, syscall.Errno) {
	targetRel, ok := inodeRel(target)
	if !ok {
		return nil, syscall.EXDEV
	}
	if r.Router.Route(targetRel) != r.Router.Route(rel) {
		return nil, syscall.EXDEV
	}
	to := r.backing(rel)
	if err := os.MkdirAll(filepath.Dir(to), 0o700); err != nil {
		return nil, fs.ToErrno(err)
	}
	if err := syscall.Link(r.backing(targetRel), to); err != nil {
		return nil, fs.ToErrno(err)
	}
	st := syscall.Stat_t{}
	if err := syscall.Lstat(to, &st); err != nil {
		_ = syscall.Unlink(to)
		return nil, fs.ToErrno(err)
	}
	return &st, 0
}

func (n *node) childRel(name string) string {
	return filepath.Clean(filepath.Join(n.rel, name))
}

func (n *node) backing() string {
	return n.root.backing(n.rel)
}

func (n *node) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	rel := n.childRel(name)
	p := n.root.backing(rel)
	st := syscall.Stat_t{}
	if err := syscall.Lstat(p, &st); err != nil {
		return nil, fs.ToErrno(err)
	}
	out.Attr.FromStat(&st)
	ch := n.NewInode(ctx, &node{root: n.root, rel: rel}, stableAttr(&st))
	return ch, 0
}

func (n *node) Getattr(ctx context.Context, f fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	if f != nil {
		if getter, ok := f.(fs.FileGetattrer); ok {
			return getter.Getattr(ctx, out)
		}
	}
	st := syscall.Stat_t{}
	if err := syscall.Lstat(n.backing(), &st); err != nil {
		return fs.ToErrno(err)
	}
	out.Attr.FromStat(&st)
	return 0
}

func (n *node) Readdir(ctx context.Context) (fs.DirStream, syscall.Errno) {
	return fs.NewLoopbackDirStream(n.backing())
}

func (n *node) OpendirHandle(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	ds, errno := fs.NewLoopbackDirStream(n.backing())
	return ds, 0, errno
}

func (n *node) Mkdir(ctx context.Context, name string, mode uint32, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	rel := n.childRel(name)
	p := n.root.backing(rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return nil, fs.ToErrno(err)
	}
	if err := os.Mkdir(p, os.FileMode(mode)); err != nil {
		return nil, fs.ToErrno(err)
	}
	st := syscall.Stat_t{}
	if err := syscall.Lstat(p, &st); err != nil {
		_ = syscall.Rmdir(p)
		return nil, fs.ToErrno(err)
	}
	out.Attr.FromStat(&st)
	ch := n.NewInode(ctx, &node{root: n.root, rel: rel}, stableAttr(&st))
	return ch, 0
}

func (n *node) Create(ctx context.Context, name string, flags uint32, mode uint32, out *fuse.EntryOut) (*fs.Inode, fs.FileHandle, uint32, syscall.Errno) {
	rel := n.childRel(name)
	p := n.root.backing(rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return nil, nil, 0, fs.ToErrno(err)
	}
	fd, err := syscall.Open(p, int(flags&^syscall.O_APPEND)|os.O_CREATE, mode)
	if err != nil {
		return nil, nil, 0, fs.ToErrno(err)
	}
	st := syscall.Stat_t{}
	if err := syscall.Fstat(fd, &st); err != nil {
		_ = syscall.Close(fd)
		return nil, nil, 0, fs.ToErrno(err)
	}
	out.Attr.FromStat(&st)
	ch := n.NewInode(ctx, &node{root: n.root, rel: rel}, stableAttr(&st))
	return ch, fs.NewLoopbackFile(fd), 0, 0
}

func (n *node) Open(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	fd, err := syscall.Open(n.backing(), int(flags&^syscall.O_APPEND), 0)
	if err != nil {
		return nil, 0, fs.ToErrno(err)
	}
	return fs.NewLoopbackFile(fd), 0, 0
}

func (n *node) Setattr(ctx context.Context, f fs.FileHandle, in *fuse.SetAttrIn, out *fuse.AttrOut) syscall.Errno {
	return setattr(ctx, n.backing(), f, in, out)
}

func (n *node) Symlink(ctx context.Context, target, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	rel := n.childRel(name)
	st, errno := n.root.symlink(target, rel)
	if errno != 0 {
		return nil, errno
	}
	out.Attr.FromStat(st)
	return n.NewInode(ctx, &node{root: n.root, rel: rel}, stableAttr(st)), 0
}

func (n *node) Link(ctx context.Context, target fs.InodeEmbedder, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	rel := n.childRel(name)
	st, errno := n.root.link(target, rel)
	if errno != 0 {
		return nil, errno
	}
	out.Attr.FromStat(st)
	return n.NewInode(ctx, &node{root: n.root, rel: rel}, stableAttr(st)), 0
}

func (n *node) Readlink(ctx context.Context) ([]byte, syscall.Errno) {
	for size := 256; ; size *= 2 {
		buf := make([]byte, size)
		n, err := syscall.Readlink(n.backing(), buf)
		if err != nil {
			return nil, fs.ToErrno(err)
		}
		if n < len(buf) {
			return buf[:n], 0
		}
	}
}

func (n *node) Unlink(ctx context.Context, name string) syscall.Errno {
	return fs.ToErrno(syscall.Unlink(n.root.backing(n.childRel(name))))
}

func (n *node) Rmdir(ctx context.Context, name string) syscall.Errno {
	return fs.ToErrno(syscall.Rmdir(n.root.backing(n.childRel(name))))
}

func (n *node) Rename(ctx context.Context, name string, newParent fs.InodeEmbedder, newName string, flags uint32) syscall.Errno {
	if flags != 0 {
		return syscall.EINVAL
	}
	other, ok := newParent.(*node)
	if !ok {
		if root, ok := newParent.(*Root); ok {
			other = root.node("/")
		} else {
			return syscall.EXDEV
		}
	}
	fromRel := n.childRel(name)
	toRel := other.childRel(newName)
	from := n.root.backing(fromRel)
	to := n.root.backing(toRel)
	if filepath.Dir(from) != filepath.Dir(to) && n.root.Router.Route(fromRel) != n.root.Router.Route(toRel) {
		return syscall.EXDEV
	}
	if err := os.MkdirAll(filepath.Dir(to), 0o700); err != nil {
		return fs.ToErrno(err)
	}
	return fs.ToErrno(syscall.Rename(from, to))
}

func setattr(ctx context.Context, p string, f fs.FileHandle, in *fuse.SetAttrIn, out *fuse.AttrOut) syscall.Errno {
	if f != nil {
		if setter, ok := f.(fs.FileSetattrer); ok {
			if errno := setter.Setattr(ctx, in, out); errno != 0 {
				return errno
			}
			return 0
		}
	}

	if mode, ok := in.GetMode(); ok {
		if err := syscall.Chmod(p, mode); err != nil {
			return fs.ToErrno(err)
		}
	}

	uid, uidOK := in.GetUID()
	gid, gidOK := in.GetGID()
	if uidOK || gidOK {
		setUID := -1
		setGID := -1
		if uidOK {
			setUID = int(uid)
		}
		if gidOK {
			setGID = int(gid)
		}
		if err := unix.Fchownat(unix.AT_FDCWD, p, setUID, setGID, unix.AT_SYMLINK_NOFOLLOW); err != nil {
			return fs.ToErrno(err)
		}
	}

	if size, ok := in.GetSize(); ok {
		if err := syscall.Truncate(p, int64(size)); err != nil {
			return fs.ToErrno(err)
		}
	}

	mtime, mtimeOK := in.GetMTime()
	atime, atimeOK := in.GetATime()
	if mtimeOK || atimeOK {
		atimeSpec := unix.Timespec{Nsec: unix.UTIME_OMIT}
		mtimeSpec := unix.Timespec{Nsec: unix.UTIME_OMIT}
		if atimeOK {
			var err error
			atimeSpec, err = unix.TimeToTimespec(atime)
			if err != nil {
				return fs.ToErrno(err)
			}
		}
		if mtimeOK {
			var err error
			mtimeSpec, err = unix.TimeToTimespec(mtime)
			if err != nil {
				return fs.ToErrno(err)
			}
		}
		if err := unix.UtimesNanoAt(unix.AT_FDCWD, p, []unix.Timespec{atimeSpec, mtimeSpec}, unix.AT_SYMLINK_NOFOLLOW); err != nil {
			return fs.ToErrno(err)
		}
	}

	if f != nil {
		if getter, ok := f.(fs.FileGetattrer); ok {
			return getter.Getattr(ctx, out)
		}
	}
	st := syscall.Stat_t{}
	if err := syscall.Lstat(p, &st); err != nil {
		return fs.ToErrno(err)
	}
	out.Attr.FromStat(&st)
	return 0
}

func inodeRel(target fs.InodeEmbedder) (string, bool) {
	switch t := target.(type) {
	case *node:
		return t.rel, true
	case *Root:
		return "/", true
	default:
		return "", false
	}
}

func stableAttr(st *syscall.Stat_t) fs.StableAttr {
	return fs.StableAttr{Mode: uint32(st.Mode), Ino: st.Ino, Gen: 1}
}
