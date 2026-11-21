// Package config loads the toom-server config file.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const (
	DefaultPort    = 4400
	ConfigFileName = "config.json"
	LogFileName    = "toom-server.log"
)

// Config is the toom-server config file content.
type Config struct {
	Port int `json:"port"`
}

// DefaultPath returns the config path next to the running binary.
func DefaultPath() string {
	exe, err := os.Executable()
	if err != nil {
		return ConfigFileName
	}
	return filepath.Join(filepath.Dir(exe), ConfigFileName)
}

// Load reads and parses the config file at path.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config %s: %w", path, err)
	}
	return Parse(data)
}

// Parse decodes config content and fills defaults.
func Parse(data []byte) (*Config, error) {
	cfg := &Config{Port: DefaultPort}
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return cfg, nil
}

// Validate checks the config values.
func (c *Config) Validate() error {
	if c.Port < 1 || c.Port > 65535 {
		return fmt.Errorf("port %d is out of range 1 to 65535", c.Port)
	}
	return nil
}

// ValidateFile loads the config and reports the first problem.
func ValidateFile(path string) error {
	_, err := Load(path)
	return err
}

// Save writes the config to path as indented JSON.
func Save(path string, cfg *Config) error {
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return os.WriteFile(path, data, 0644)
}

// LoadOrCreate loads the config file, or writes one with default
// values when the file does not exist. The flag reports a fresh file.
func LoadOrCreate(path string) (*Config, bool, error) {
	cfg, err := Load(path)
	if err == nil {
		return cfg, false, nil
	}
	if !os.IsNotExist(errors.Unwrap(err)) && !os.IsNotExist(err) {
		return nil, false, err
	}
	cfg = &Config{Port: DefaultPort}
	if err := Save(path, cfg); err != nil {
		return nil, false, fmt.Errorf("failed to write default config %s: %w", path, err)
	}
	return cfg, true, nil
}
