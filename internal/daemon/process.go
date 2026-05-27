package daemon

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

type ProcessSpec struct {
	Key          string
	Binary       string
	Args         []string
	Env          []string
	Dir          string
	LogPath      string
	Restart      bool
	RestartDelay time.Duration
}

type ProcessStats struct {
	Starts           uint64
	Exits            uint64
	RestartAttempts  uint64
	RestartSuccesses uint64
	RestartFailures  uint64
}

type ProcessManager struct {
	mu      sync.Mutex
	procs   map[string]*exec.Cmd
	done    map[*exec.Cmd]chan struct{}
	desired map[string]bool
	stats   ProcessStats
}

func NewProcessManager() *ProcessManager {
	return &ProcessManager{
		procs:   map[string]*exec.Cmd{},
		done:    map[*exec.Cmd]chan struct{}{},
		desired: map[string]bool{},
	}
}

func (m *ProcessManager) Start(spec ProcessSpec) error {
	if spec.Key == "" || spec.Binary == "" {
		return fmt.Errorf("process key and binary are required")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if cmd := m.procs[spec.Key]; cmd != nil && cmd.Process != nil && cmd.ProcessState == nil {
		if spec.Restart {
			m.desired[spec.Key] = true
		} else {
			delete(m.desired, spec.Key)
		}
		return nil
	}
	if err := m.startLocked(spec); err != nil {
		delete(m.desired, spec.Key)
		return err
	}
	if spec.Restart {
		m.desired[spec.Key] = true
	} else {
		delete(m.desired, spec.Key)
	}
	return nil
}

func (m *ProcessManager) startLocked(spec ProcessSpec) error {
	path, err := exec.LookPath(spec.Binary)
	if err != nil {
		return err
	}
	cmd := exec.Command(path, spec.Args...)
	cmd.Dir = spec.Dir
	cmd.Env = append(os.Environ(), spec.Env...)
	var logFile *os.File
	if spec.LogPath != "" {
		if err := os.MkdirAll(filepath.Dir(spec.LogPath), 0o700); err != nil {
			return err
		}
		f, err := os.OpenFile(spec.LogPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if err != nil {
			return err
		}
		logFile = f
		cmd.Stdout = f
		cmd.Stderr = f
	}
	if err := cmd.Start(); err != nil {
		if logFile != nil {
			_ = logFile.Close()
		}
		return err
	}
	if logFile != nil {
		_ = logFile.Close()
	}
	done := make(chan struct{})
	m.procs[spec.Key] = cmd
	m.done[cmd] = done
	m.stats.Starts++
	go m.wait(spec, cmd, done)
	return nil
}

func (m *ProcessManager) wait(spec ProcessSpec, cmd *exec.Cmd, done chan struct{}) {
	_ = cmd.Wait()
	restart := false
	m.mu.Lock()
	if m.procs[spec.Key] == cmd {
		delete(m.procs, spec.Key)
		restart = spec.Restart
	}
	delete(m.done, cmd)
	m.stats.Exits++
	m.mu.Unlock()
	close(done)
	if restart {
		m.restart(spec)
	}
}

func (m *ProcessManager) restart(spec ProcessSpec) {
	delay := spec.RestartDelay
	if delay <= 0 {
		delay = time.Second
	}
	for {
		time.Sleep(delay)
		m.mu.Lock()
		if !m.desired[spec.Key] {
			m.mu.Unlock()
			return
		}
		if existing := m.procs[spec.Key]; existing != nil && existing.Process != nil && existing.ProcessState == nil {
			m.mu.Unlock()
			return
		}
		m.stats.RestartAttempts++
		err := m.startLocked(spec)
		if err != nil {
			m.stats.RestartFailures++
			m.mu.Unlock()
			continue
		}
		m.stats.RestartSuccesses++
		m.mu.Unlock()
		return
	}
}

func (m *ProcessManager) Count() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.procs)
}

func (m *ProcessManager) DesiredCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.desired)
}

func (m *ProcessManager) UnhealthyCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.unhealthyCountLocked()
}

func (m *ProcessManager) unhealthyCountLocked() int {
	unhealthy := 0
	for key := range m.desired {
		cmd := m.procs[key]
		if cmd == nil || cmd.Process == nil || cmd.ProcessState != nil {
			unhealthy++
		}
	}
	return unhealthy
}

func (m *ProcessManager) Stats() ProcessStats {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.stats
}

func (m *ProcessManager) IsRunning(key string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	cmd := m.procs[key]
	return cmd != nil && cmd.Process != nil && cmd.ProcessState == nil
}

func (m *ProcessManager) IsDesired(key string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.desired[key]
}

func (m *ProcessManager) Stop(key string) error {
	m.mu.Lock()
	cmd := m.procs[key]
	delete(m.procs, key)
	delete(m.desired, key)
	done := m.done[cmd]
	m.mu.Unlock()
	if cmd == nil || cmd.Process == nil || cmd.ProcessState != nil {
		return nil
	}
	_ = cmd.Process.Signal(os.Interrupt)
	if done != nil {
		select {
		case <-done:
			return nil
		case <-time.After(2 * time.Second):
		}
	}
	return cmd.Process.Kill()
}
