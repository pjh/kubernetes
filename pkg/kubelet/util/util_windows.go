// +build windows

/*
Copyright 2017 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package util

import (
	"fmt"
	"net"
	"net/url"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"k8s.io/klog"
	"github.com/Microsoft/go-winio"
	"github.com/pkg/errors"
	"golang.org/x/sys/windows"
)

const (
	tcpProtocol   = "tcp"
	npipeProtocol = "npipe"

	reparseTagSocket = 0x80000023

	msgNotAReparsePoint = "The file or directory is not a reparse point."
)

// CreateListener creates a listener on the specified endpoint.
func CreateListener(endpoint string) (net.Listener, error) {
	protocol, addr, err := parseEndpoint(endpoint)
	if err != nil {
		return nil, err
	}

	switch protocol {
	case tcpProtocol:
		return net.Listen(tcpProtocol, addr)

	case npipeProtocol:
		return winio.ListenPipe(addr, nil)

	default:
		return nil, fmt.Errorf("only support tcp and npipe endpoint")
	}
}

// GetAddressAndDialer returns the address parsed from the given endpoint and a dialer.
func GetAddressAndDialer(endpoint string) (string, func(addr string, timeout time.Duration) (net.Conn, error), error) {
	protocol, addr, err := parseEndpoint(endpoint)
	if err != nil {
		return "", nil, err
	}

	if protocol == tcpProtocol {
		return addr, tcpDial, nil
	}

	if protocol == npipeProtocol {
		return addr, npipeDial, nil
	}

	return "", nil, fmt.Errorf("only support tcp and npipe endpoint")
}

func tcpDial(addr string, timeout time.Duration) (net.Conn, error) {
	return net.DialTimeout(tcpProtocol, addr, timeout)
}

func npipeDial(addr string, timeout time.Duration) (net.Conn, error) {
	return winio.DialPipe(addr, &timeout)
}

func parseEndpoint(endpoint string) (string, string, error) {
	// url.Parse doesn't recognize \, so replace with / first.
	endpoint = strings.Replace(endpoint, "\\", "/", -1)
	u, err := url.Parse(endpoint)
	if err != nil {
		return "", "", err
	}

	if u.Scheme == "tcp" {
		return "tcp", u.Host, nil
	} else if u.Scheme == "npipe" {
		if strings.HasPrefix(u.Path, "//./pipe") {
			return "npipe", u.Path, nil
		}

		// fallback host if not provided.
		host := u.Host
		if host == "" {
			host = "."
		}
		return "npipe", fmt.Sprintf("//%s%s", host, u.Path), nil
	} else if u.Scheme == "" {
		return "", "", fmt.Errorf("Using %q as endpoint is deprecated, please consider using full url format", endpoint)
	} else {
		return u.Scheme, "", fmt.Errorf("protocol %q not supported", u.Scheme)
	}
}

// LocalEndpoint empty implementation
func LocalEndpoint(path, file string) (string, error) {
	return "", fmt.Errorf("LocalEndpoints are unsupported in this build")
}

var tickCount = syscall.NewLazyDLL("kernel32.dll").NewProc("GetTickCount64")

// GetBootTime returns the time at which the machine was started, truncated to the nearest second
func GetBootTime() (time.Time, error) {
	currentTime := time.Now()
	output, _, err := tickCount.Call()
	if errno, ok := err.(syscall.Errno); !ok || errno != 0 {
		return time.Time{}, err
	}
	return currentTime.Add(-time.Duration(output) * time.Millisecond).Truncate(time.Second), nil
}

type reparseDataBufferHeader struct {
	ReparseTag        uint32
	ReparseDataLength uint16
	Reserved          uint16
}

type reparseDataBuffer struct {
	Header reparseDataBufferHeader
	Detail [syscall.MAXIMUM_REPARSE_DATA_BUFFER_SIZE]byte
}

// IsUnixDomainSocket returns whether a given file is a AF_UNIX socket file
func IsUnixDomainSocket(filePath string) (bool, error) {
	// Due to the absence of golang support for os.ModeSocket in Windows (https://github.com/golang/go/issues/33357)
	// we need to get the Reparse Points (https://docs.microsoft.com/en-us/windows/win32/fileio/reparse-points)
	// for the file (using FSCTL_GET_REPARSE_POINT) and check for reparse tag: reparseTagSocket

	// Get a handle on the existing domain socket file using CreateFile. Note that CreateFile invoked with OPEN_EXISTING
	// opens an existing file - no new file is created here that requires cleanup. CloseHandle will clean up the file handle
	// CSI-prototype: force
	if strings.Contains(filePath, "filestore") {
		klog.Warningf("CSI-prototype: filePath contains filestore, returning true for IsUnixDomainSocket")
		return true, nil
	}
	fd, err := windows.CreateFile(windows.StringToUTF16Ptr(filePath), windows.GENERIC_READ, 0, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT|windows.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		return false, errors.Wrap(err, "CreateFile failed")
	}
	defer windows.CloseHandle(fd)

	rdbbuf := make([]byte, syscall.MAXIMUM_REPARSE_DATA_BUFFER_SIZE)
	var bytesReturned uint32
	// Issue FSCTL_GET_REPARSE_POINT (https://docs.microsoft.com/en-us/windows-hardware/drivers/ifs/fsctl-get-reparse-point)
	if err := windows.DeviceIoControl(fd, windows.FSCTL_GET_REPARSE_POINT, nil, 0, &rdbbuf[0], uint32(len(rdbbuf)), &bytesReturned, nil); err != nil {
		if err.Error() == msgNotAReparsePoint {
			return false, nil
		}
		return false, errors.Wrap(err, "FSCTL_GET_REPARSE_POINT failed")
	}
	rdb := (*reparseDataBuffer)(unsafe.Pointer(&rdbbuf[0]))
	return (rdb.Header.ReparseTag == reparseTagSocket), nil
}

// NormalizePath converts FS paths returned by certain go frameworks (like fsnotify)
// to native Windows paths that can be passed to Windows specific code
func NormalizePath(path string) string {
	path = strings.ReplaceAll(path, "/", "\\")
	if strings.HasPrefix(path, "\\") {
		path = "c:" + path
	}
	return path
}
