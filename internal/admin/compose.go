package admin

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"strings"

	"gopkg.in/yaml.v3"
)

var composeVolumeLabelKeys = map[string]bool{
	"cs.mode":   true,
	"cs.write":  true,
	"cs.engine": true,
	"cs.crypt":  true,
	"cs.backup": true,
}

// RenderCompose copies supported cs-storage volume labels into driver_opts so
// Docker Stack/Compose deployments pass them through the VolumeDriver API.
func RenderCompose(r io.Reader, w io.Writer) error {
	var doc yaml.Node
	dec := yaml.NewDecoder(r)
	if err := dec.Decode(&doc); err != nil {
		return err
	}
	root := documentRoot(&doc)
	if root == nil || root.Kind != yaml.MappingNode {
		return errors.New("compose document must be a mapping")
	}
	volumes := mappingValue(root, "volumes")
	if volumes != nil {
		if volumes.Kind != yaml.MappingNode {
			return errors.New("compose volumes must be a mapping")
		}
		if err := renderComposeVolumes(volumes); err != nil {
			return err
		}
	}
	enc := yaml.NewEncoder(w)
	enc.SetIndent(2)
	if err := enc.Encode(&doc); err != nil {
		_ = enc.Close()
		return err
	}
	return enc.Close()
}

func RenderComposeBytes(in []byte) ([]byte, error) {
	var out bytes.Buffer
	if err := RenderCompose(bytes.NewReader(in), &out); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func renderComposeVolumes(volumes *yaml.Node) error {
	for i := 0; i+1 < len(volumes.Content); i += 2 {
		name := volumes.Content[i].Value
		volume := volumes.Content[i+1]
		if volume.Kind == yaml.ScalarNode && (volume.Tag == "!!null" || volume.Value == "") {
			continue
		}
		if volume.Kind != yaml.MappingNode {
			return fmt.Errorf("volume %q must be a mapping", name)
		}
		labels := mappingValue(volume, "labels")
		if labels == nil {
			continue
		}
		entries, err := composeLabelEntries(labels)
		if err != nil {
			return fmt.Errorf("volume %q labels: %w", name, err)
		}
		if len(entries) == 0 {
			continue
		}
		driverOpts := ensureMappingValue(volume, "driver_opts")
		for _, entry := range entries {
			key := strings.TrimSpace(entry.key)
			if key == "flush" || key == "cs.flush" {
				return fmt.Errorf("volume %q label %q is destructive and must be specified only as driver_opts.flush", name, key)
			}
			if !composeVolumeLabelKeys[key] {
				continue
			}
			if mappingValue(driverOpts, key) != nil {
				continue
			}
			appendScalarPair(driverOpts, key, entry.value)
		}
	}
	return nil
}

type composeLabelEntry struct {
	key   string
	value string
}

func composeLabelEntries(labels *yaml.Node) ([]composeLabelEntry, error) {
	switch labels.Kind {
	case yaml.MappingNode:
		entries := make([]composeLabelEntry, 0, len(labels.Content)/2)
		for i := 0; i+1 < len(labels.Content); i += 2 {
			entries = append(entries, composeLabelEntry{key: labels.Content[i].Value, value: labels.Content[i+1].Value})
		}
		return entries, nil
	case yaml.SequenceNode:
		entries := make([]composeLabelEntry, 0, len(labels.Content))
		for _, item := range labels.Content {
			if item.Kind != yaml.ScalarNode {
				return nil, errors.New("sequence labels must be scalar key=value strings")
			}
			key, value, ok := strings.Cut(item.Value, "=")
			if !ok {
				key = item.Value
				value = ""
			}
			entries = append(entries, composeLabelEntry{key: key, value: value})
		}
		return entries, nil
	default:
		return nil, errors.New("labels must be a mapping or sequence")
	}
}

func documentRoot(doc *yaml.Node) *yaml.Node {
	if doc.Kind == yaml.DocumentNode && len(doc.Content) > 0 {
		return doc.Content[0]
	}
	return doc
}

func mappingValue(n *yaml.Node, key string) *yaml.Node {
	if n == nil || n.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(n.Content); i += 2 {
		if n.Content[i].Value == key {
			return n.Content[i+1]
		}
	}
	return nil
}

func ensureMappingValue(n *yaml.Node, key string) *yaml.Node {
	if existing := mappingValue(n, key); existing != nil {
		return existing
	}
	k := scalarNode(key)
	v := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
	n.Content = append(n.Content, k, v)
	return v
}

func appendScalarPair(n *yaml.Node, key, value string) {
	n.Content = append(n.Content, scalarNode(key), scalarNode(value))
}

func scalarNode(v string) *yaml.Node {
	return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: v}
}
