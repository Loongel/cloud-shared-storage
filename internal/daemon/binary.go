package daemon

import "os"

func packagedBinary(name string, fallback string) string {
	path := "/usr/lib/cs-storage/bin/" + name
	if st, err := os.Stat(path); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
		return path
	}
	return fallback
}
