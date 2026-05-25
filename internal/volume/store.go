package volume

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
)

type Metadata struct {
	Name       string          `json:"name"`
	Mountpoint string          `json:"mountpoint"`
	Options    Options         `json:"-"`
	MountIDs   map[string]bool `json:"mount_ids,omitempty"`
}

type Store struct {
	mu   sync.Mutex
	path string
	data map[string]Metadata
}

func NewStore(path string) (*Store, error) {
	s := &Store{path: path, data: map[string]Metadata{}}
	if err := s.Load(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) Load() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	return json.Unmarshal(b, &s.data)
}

func (s *Store) Save() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.saveLocked()
}

func (s *Store) Upsert(m Metadata) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data[m.Name] = storedMetadata(m)
	return s.saveLocked()
}

func (s *Store) Get(name string) (Metadata, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.data[name]
	return m, ok
}

func (s *Store) Delete(name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.data, name)
	return s.saveLocked()
}

func (s *Store) List() []Metadata {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Metadata, 0, len(s.data))
	for _, m := range s.data {
		out = append(out, m)
	}
	return out
}

func storedMetadata(m Metadata) Metadata {
	m.Options = Options{}
	return m
}

func (s *Store) saveLocked() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(s.data, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.path, b, 0o600)
}
