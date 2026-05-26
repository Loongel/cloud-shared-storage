package routerfuse

import (
	"context"
	"syscall"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

type routedFile struct {
	inner *fs.LoopbackFile
}

func newRoutedFile(fd int) fs.FileHandle {
	return &routedFile{inner: fs.NewLoopbackFile(fd).(*fs.LoopbackFile)}
}

func (f *routedFile) Read(ctx context.Context, buf []byte, off int64) (fuse.ReadResult, syscall.Errno) {
	return f.inner.Read(ctx, buf, off)
}

func (f *routedFile) Write(ctx context.Context, data []byte, off int64) (uint32, syscall.Errno) {
	return f.inner.Write(ctx, data, off)
}

func (f *routedFile) Release(ctx context.Context) syscall.Errno {
	return f.inner.Release(ctx)
}

func (f *routedFile) Flush(ctx context.Context) syscall.Errno {
	return f.inner.Flush(ctx)
}

func (f *routedFile) Fsync(ctx context.Context, flags uint32) syscall.Errno {
	return f.inner.Fsync(ctx, flags)
}

func (f *routedFile) Getattr(ctx context.Context, out *fuse.AttrOut) syscall.Errno {
	return f.inner.Getattr(ctx, out)
}

func (f *routedFile) Getlk(ctx context.Context, owner uint64, lk *fuse.FileLock, flags uint32, out *fuse.FileLock) syscall.Errno {
	return f.inner.Getlk(ctx, owner, lk, flags, out)
}

func (f *routedFile) Setlk(ctx context.Context, owner uint64, lk *fuse.FileLock, flags uint32) syscall.Errno {
	return f.inner.Setlk(ctx, owner, lk, flags)
}

func (f *routedFile) Setlkw(ctx context.Context, owner uint64, lk *fuse.FileLock, flags uint32) syscall.Errno {
	return f.inner.Setlkw(ctx, owner, lk, flags)
}

func (f *routedFile) Lseek(ctx context.Context, off uint64, whence uint32) (uint64, syscall.Errno) {
	return f.inner.Lseek(ctx, off, whence)
}

func (f *routedFile) Setattr(ctx context.Context, in *fuse.SetAttrIn, out *fuse.AttrOut) syscall.Errno {
	return f.inner.Setattr(ctx, in, out)
}
