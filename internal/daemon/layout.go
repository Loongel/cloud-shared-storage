package daemon

import "path/filepath"

type Layout struct {
	Root        string
	Mountpoint  string
	Remote      string
	Cipher      string
	Cache       string
	Logs        string
	Config      string
	LiteFSData  string
	LiteFSMount string
	Gluster     string
	LocalDisk   string
}

func (s *Server) layout(name string) Layout {
	root := s.volumeRoot(name)
	return Layout{
		Root:        root,
		Mountpoint:  filepath.Join(root, "mount"),
		Remote:      filepath.Join(root, "remote"),
		Cipher:      filepath.Join(root, "local", "cipher"),
		Cache:       filepath.Join(root, "cache"),
		Logs:        filepath.Join(root, "logs"),
		Config:      filepath.Join(root, "config"),
		LiteFSData:  filepath.Join(root, "litefs-data"),
		LiteFSMount: filepath.Join(root, "litefs-mount"),
		Gluster:     filepath.Join(root, "gluster"),
		LocalDisk:   filepath.Join(root, "local"),
	}
}
