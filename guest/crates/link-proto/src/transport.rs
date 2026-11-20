//! Finds and opens the channel to the host (PROTOCOL.md §1). The guest always opens it.
use std::io;
use std::time::Duration;

/// Read half. `timeout` supports the stall rule; `Ok(None)` means nothing arrived in time.
pub trait LinkRead: Send {
    fn read_timeout(&mut self, buf: &mut [u8], timeout: Option<Duration>) -> io::Result<Option<usize>>;
}

pub trait LinkWrite: Send {
    fn write_all(&mut self, buf: &[u8]) -> io::Result<()>;
}

pub struct Connection {
    pub reader: Box<dyn LinkRead>,
    pub writer: Box<dyn LinkWrite>,
    pub description: String,
}

#[cfg(unix)]
mod imp {
    use super::*;
    use std::fs::File;
    use std::io::{Read, Write};
    use std::os::fd::AsRawFd;
    #[cfg(target_os = "linux")]
    use std::os::fd::FromRawFd;

    pub struct FdHalf(pub File);

    impl LinkRead for FdHalf {
        fn read_timeout(&mut self, buf: &mut [u8], timeout: Option<Duration>) -> io::Result<Option<usize>> {
            if let Some(t) = timeout {
                let mut pfd = libc::pollfd { fd: self.0.as_raw_fd(), events: libc::POLLIN, revents: 0 };
                loop {
                    let n = unsafe { libc::poll(&mut pfd, 1, t.as_millis() as libc::c_int) };
                    if n > 0 { break; }
                    if n == 0 { return Ok(None); }
                    let e = io::Error::last_os_error();
                    if e.kind() != io::ErrorKind::Interrupted { return Err(e); }
                }
            }
            loop {
                match self.0.read(buf) {
                    Ok(n) => return Ok(Some(n)),
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e),
                }
            }
        }
    }

    impl LinkWrite for FdHalf {
        fn write_all(&mut self, buf: &[u8]) -> io::Result<()> { Write::write_all(&mut self.0, buf) }
    }

    pub fn from_file(file: File, description: String) -> io::Result<Connection> {
        let other = file.try_clone()?;
        Ok(Connection { reader: Box::new(FdHalf(file)), writer: Box::new(FdHalf(other)), description })
    }

    /// The virtio-serial port whose sysfs name matches (QEMU guests).
    #[cfg(target_os = "linux")]
    pub fn find_serial_port() -> Option<std::path::PathBuf> {
        for entry in std::fs::read_dir("/sys/class/virtio-ports").ok()?.flatten() {
            let name = std::fs::read_to_string(entry.path().join("name")).unwrap_or_default();
            if name.trim() == crate::SERIAL_PORT_NAME {
                return Some(std::path::Path::new("/dev").join(entry.file_name()));
            }
        }
        None
    }

    #[cfg(target_os = "linux")]
    fn connect_vsock() -> io::Result<File> {
        unsafe {
            let fd = libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0);
            if fd < 0 { return Err(io::Error::last_os_error()); }
            let mut addr: libc::sockaddr_vm = std::mem::zeroed();
            addr.svm_family = libc::AF_VSOCK as libc::sa_family_t;
            addr.svm_cid = libc::VMADDR_CID_HOST;
            addr.svm_port = crate::VSOCK_PORT;
            let rc = libc::connect(fd, &addr as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_vm>() as libc::socklen_t);
            if rc != 0 {
                let e = io::Error::last_os_error();
                libc::close(fd);
                return Err(e);
            }
            Ok(File::from_raw_fd(fd))
        }
    }

    #[cfg(target_os = "linux")]
    pub fn connect() -> io::Result<Connection> {
        if let Some(path) = find_serial_port() {
            let file = std::fs::OpenOptions::new().read(true).write(true).open(&path)?;
            return from_file(file, format!("virtio-serial {}", path.display()));
        }
        // The vsock transport module is not always loaded automatically.
        let _ = std::process::Command::new("modprobe").arg("vmw_vsock_virtio_transport")
            .stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status();
        let file = connect_vsock()?;
        from_file(file, format!("vsock host:{}", crate::VSOCK_PORT))
    }

    /// macOS guests on Apple's Virtualization framework: a virtio socket to the host. The SDK has
    /// `AF_VSOCK` and `struct sockaddr_vm` (sys/vsock.h); the libc crate has only the constant.
    #[cfg(target_os = "macos")]
    #[repr(C)]
    pub(crate) struct SockaddrVm {
        pub svm_len: u8,
        pub svm_family: libc::sa_family_t,
        pub svm_reserved1: u16,
        pub svm_port: u32,
        pub svm_cid: u32,
    }

    #[cfg(target_os = "macos")]
    const VMADDR_CID_HOST: u32 = 2;

    #[cfg(target_os = "macos")]
    fn connect_vsock() -> io::Result<File> {
        use std::os::fd::FromRawFd;
        unsafe {
            let fd = libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM, 0);
            if fd < 0 { return Err(io::Error::last_os_error()); }
            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
            let addr = SockaddrVm {
                svm_len: std::mem::size_of::<SockaddrVm>() as u8,
                svm_family: libc::AF_VSOCK as libc::sa_family_t,
                svm_reserved1: 0,
                svm_port: crate::VSOCK_PORT,
                svm_cid: VMADDR_CID_HOST,
            };
            let rc = libc::connect(fd, &addr as *const _ as *const libc::sockaddr, std::mem::size_of::<SockaddrVm>() as libc::socklen_t);
            if rc != 0 {
                let e = io::Error::last_os_error();
                libc::close(fd);
                return Err(e);
            }
            Ok(File::from_raw_fd(fd))
        }
    }

    #[cfg(target_os = "macos")]
    pub fn connect() -> io::Result<Connection> {
        let file = connect_vsock()?;
        from_file(file, format!("vsock host:{}", crate::VSOCK_PORT))
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    pub fn connect() -> io::Result<Connection> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "no guest transport on this platform"))
    }

    /// The layout must match `struct sockaddr_vm` in the macOS SDK: 12 bytes, port at 4, cid at 8.
    #[cfg(all(test, target_os = "macos"))]
    #[test]
    fn sockaddr_vm_matches_the_sdk() {
        let a = SockaddrVm { svm_len: 0, svm_family: 0, svm_reserved1: 0, svm_port: 0, svm_cid: 0 };
        let base = &a as *const _ as usize;
        assert_eq!(std::mem::size_of::<SockaddrVm>(), 12);
        assert_eq!(&a.svm_family as *const _ as usize - base, 1);
        assert_eq!(&a.svm_port as *const _ as usize - base, 4);
        assert_eq!(&a.svm_cid as *const _ as usize - base, 8);
    }
}

#[cfg(windows)]
mod imp {
    //! UNTESTED: written against the Windows API documentation. It builds but has never run.
    //! A virtio-serial port is a device handle. It is opened for overlapped I/O because a blocking
    //! read on a synchronous handle would block writes from the other thread.
    use super::*;
    use std::sync::Arc;
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, ERROR_IO_PENDING, GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Storage::FileSystem::{CreateFileW, ReadFile, WriteFile, FILE_FLAG_OVERLAPPED, OPEN_EXISTING};
    use windows_sys::Win32::System::Threading::CreateEventW;
    use windows_sys::Win32::System::IO::{GetOverlappedResult, OVERLAPPED};

    struct Port(HANDLE);
    unsafe impl Send for Port {}
    unsafe impl Sync for Port {}
    impl Drop for Port {
        fn drop(&mut self) { unsafe { CloseHandle(self.0); } }
    }

    struct Half { port: Arc<Port>, event: HANDLE }
    unsafe impl Send for Half {}
    impl Drop for Half {
        fn drop(&mut self) { unsafe { CloseHandle(self.event); } }
    }

    impl Half {
        fn new(port: Arc<Port>) -> io::Result<Half> {
            let event = unsafe { CreateEventW(std::ptr::null(), 1, 0, std::ptr::null()) };
            if event.is_null() { return Err(io::Error::last_os_error()); }
            Ok(Half { port, event })
        }

        /// Runs one overlapped operation to completion.
        fn finish(&self, started: i32, ov: &mut OVERLAPPED) -> io::Result<usize> {
            let mut n: u32 = 0;
            if started == 0 && unsafe { GetLastError() } != ERROR_IO_PENDING {
                return Err(io::Error::last_os_error());
            }
            if unsafe { GetOverlappedResult(self.port.0, ov, &mut n, 1) } == 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(n as usize)
        }
    }

    impl LinkRead for Half {
        /// The timeout is ignored on Windows: the stall rule is applied by the host only.
        fn read_timeout(&mut self, buf: &mut [u8], _timeout: Option<Duration>) -> io::Result<Option<usize>> {
            let mut ov: OVERLAPPED = unsafe { std::mem::zeroed() };
            ov.hEvent = self.event;
            let started = unsafe { ReadFile(self.port.0, buf.as_mut_ptr(), buf.len() as u32, std::ptr::null_mut(), &mut ov) };
            self.finish(started, &mut ov).map(Some)
        }
    }

    impl LinkWrite for Half {
        fn write_all(&mut self, mut buf: &[u8]) -> io::Result<()> {
            while !buf.is_empty() {
                let mut ov: OVERLAPPED = unsafe { std::mem::zeroed() };
                ov.hEvent = self.event;
                let started = unsafe { WriteFile(self.port.0, buf.as_ptr(), buf.len() as u32, std::ptr::null_mut(), &mut ov) };
                let n = self.finish(started, &mut ov)?;
                if n == 0 { return Err(io::Error::new(io::ErrorKind::WriteZero, "port closed")); }
                buf = &buf[n..];
            }
            Ok(())
        }
    }

    pub fn connect() -> io::Result<Connection> {
        // The vioserial driver publishes each named port as a device symlink. Try the session-independent
        // name first, then the plain one.
        let mut opened = None;
        let mut last_error = io::Error::new(io::ErrorKind::NotFound, "no virtio-serial port");
        for path in [format!(r"\\.\Global\{}", crate::SERIAL_PORT_NAME), format!(r"\\.\{}", crate::SERIAL_PORT_NAME)] {
            let wide: Vec<u16> = path.encode_utf16().chain(std::iter::once(0)).collect();
            let handle = unsafe {
                CreateFileW(wide.as_ptr(), GENERIC_READ | GENERIC_WRITE, 0, std::ptr::null(), OPEN_EXISTING, FILE_FLAG_OVERLAPPED, std::ptr::null_mut())
            };
            if handle == INVALID_HANDLE_VALUE { last_error = io::Error::last_os_error(); continue; }
            opened = Some((handle, path));
            break;
        }
        let Some((handle, path)) = opened else { return Err(last_error) };
        let port = Arc::new(Port(handle));
        Ok(Connection {
            reader: Box::new(Half::new(port.clone())?),
            writer: Box::new(Half::new(port)?),
            description: format!("virtio-serial {path}"),
        })
    }
}

/// Opens the channel to the host, or fails if no transport is present yet.
pub fn connect() -> io::Result<Connection> { imp::connect() }

#[cfg(unix)]
pub use imp::from_file;
