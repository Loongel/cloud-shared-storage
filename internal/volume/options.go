package volume

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

type Options struct {
	Mode   string `json:"mode"`
	Write  string `json:"write"`
	Engine string `json:"engine"`
	Crypt  bool   `json:"crypt"`
	Backup bool   `json:"backup"`
	Flush  bool   `json:"flush"`
}

func (o *Options) UnmarshalJSON(data []byte) error {
	type optionsAlias struct {
		Mode   string          `json:"mode"`
		Write  string          `json:"write"`
		Engine string          `json:"engine"`
		Crypt  bool            `json:"crypt"`
		Backup json.RawMessage `json:"backup"`
		Flush  bool            `json:"flush"`
	}
	var raw optionsAlias
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	o.Mode = raw.Mode
	o.Write = raw.Write
	o.Engine = raw.Engine
	o.Crypt = raw.Crypt
	o.Flush = raw.Flush
	if len(raw.Backup) == 0 || string(raw.Backup) == "null" {
		o.Backup = false
		return nil
	}
	var backupBool bool
	if err := json.Unmarshal(raw.Backup, &backupBool); err == nil {
		o.Backup = backupBool
		return nil
	}
	var backupString string
	if err := json.Unmarshal(raw.Backup, &backupString); err != nil {
		return err
	}
	switch strings.ToLower(backupString) {
	case "true":
		o.Backup = true
	case "", "false":
		o.Backup = false
	default:
		return fmt.Errorf("invalid stored backup value %q", backupString)
	}
	return nil
}

func ParseOptions(raw map[string]string) (Options, error) {
	return ParseDriverOptions(raw, nil)
}

func ParseDriverOptions(optsRaw, labelsRaw map[string]string) (Options, error) {
	opts := Options{
		Mode:   "private",
		Write:  "single",
		Engine: "auto",
		Crypt:  true,
		Backup: false,
	}
	if hasKey(labelsRaw, "flush", "cs.flush") {
		return opts, errors.New("flush is destructive and may only be set in driver opts")
	}

	raw := mergeLabelsAndOpts(labelsRaw, optsRaw)
	if v := pick(raw, "cs.mode", "mode"); v != "" {
		opts.Mode = strings.ToLower(v)
	}
	if v := pick(raw, "cs.write", "write"); v != "" {
		opts.Write = strings.ToLower(v)
	}
	if v := pick(raw, "cs.engine", "engine"); v != "" {
		opts.Engine = strings.ToLower(v)
	}
	if v := pick(raw, "cs.crypt", "crypt"); v != "" {
		switch strings.ToLower(v) {
		case "1", "true", "yes", "on":
			opts.Crypt = true
		case "0", "false", "no", "off":
			opts.Crypt = false
		default:
			return opts, fmt.Errorf("invalid cs.crypt value %q", v)
		}
	}
	if v := pick(raw, "cs.backup"); v != "" {
		switch strings.ToLower(v) {
		case "true":
			opts.Backup = true
		case "false":
			opts.Backup = false
		default:
			return opts, fmt.Errorf("invalid cs.backup value %q", v)
		}
	}
	if v := pick(raw, "flush"); v != "" {
		switch strings.ToLower(v) {
		case "1", "true", "yes", "on":
			opts.Flush = true
		case "0", "false", "no", "off":
			opts.Flush = false
		default:
			return opts, fmt.Errorf("invalid flush value %q", v)
		}
	}
	return opts, opts.Validate()
}

func (o Options) Validate() error {
	if o.Mode != "private" && o.Mode != "shared" {
		return errors.New("cs.mode must be private or shared")
	}
	if o.Write != "single" && o.Write != "multi" {
		return errors.New("cs.write must be single or multi")
	}
	if o.Engine != "auto" && o.Engine != "static" && o.Engine != "sqlite" {
		return errors.New("cs.engine must be auto, static, or sqlite")
	}
	if o.Mode == "private" && o.Write == "multi" {
		return errors.New("cs.write=multi requires cs.mode=shared")
	}
	return nil
}

func (o Options) NeedsRealtimeRclone() bool {
	return o.Mode == "private" || o.Write == "single"
}

func pick(raw map[string]string, keys ...string) string {
	for _, k := range keys {
		if v := raw[k]; v != "" {
			return v
		}
	}
	return ""
}

func hasKey(raw map[string]string, keys ...string) bool {
	for _, k := range keys {
		if _, ok := raw[k]; ok {
			return true
		}
	}
	return false
}

func mergeLabelsAndOpts(labelsRaw, optsRaw map[string]string) map[string]string {
	if labelsRaw == nil && optsRaw == nil {
		return nil
	}
	merged := make(map[string]string, len(labelsRaw)+len(optsRaw))
	for k, v := range labelsRaw {
		merged[k] = v
	}
	for k, v := range optsRaw {
		merged[k] = v
	}
	return merged
}
