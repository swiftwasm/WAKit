import SystemExtras
import SystemPackage

extension WASIAbi.FileType {
    init(platformFileType: FileDescriptor.FileType) {
        if platformFileType.isDirectory {
            self = .DIRECTORY
        } else if platformFileType.isSymlink {
            self = .SYMBOLIC_LINK
        } else if platformFileType.isFile {
            self = .REGULAR_FILE
        } else if platformFileType.isCharacterDevice {
            self = .CHARACTER_DEVICE
        } else if platformFileType.isBlockDevice {
            self = .BLOCK_DEVICE
        } else if platformFileType.isSocket {
            self = .SOCKET_STREAM
        } else {
            self = .UNKNOWN
        }
    }
}

extension WASIAbi.Fdflags {
    init(platformOpenOptions: FileDescriptor.OpenOptions) {
        var fdFlags: WASIAbi.Fdflags = []
        if platformOpenOptions.contains(.append) {
            fdFlags.insert(.APPEND)
        }
        if platformOpenOptions.contains(.dataSync) {
            fdFlags.insert(.DSYNC)
        }
        if platformOpenOptions.contains(.nonBlocking) {
            fdFlags.insert(.NONBLOCK)
        }
        if platformOpenOptions.contains(.fileSync) {
            fdFlags.insert(.SYNC)
        }
        #if os(Linux)
            if platformOpenOptions.contains(.readSync) {
                fdFlags.insert(.RSYNC)
            }
        #endif
        self = fdFlags
    }

    var platformOpenOptions: FileDescriptor.OpenOptions {
        var flags: FileDescriptor.OpenOptions = []
        if self.contains(.APPEND) {
            flags.insert(.append)
        }
        if self.contains(.DSYNC) {
            flags.insert(.dataSync)
        }
        if self.contains(.NONBLOCK) {
            flags.insert(.nonBlocking)
        }
        if self.contains(.SYNC) {
            flags.insert(.fileSync)
        }
        #if os(Linux)
            if self.contains(.RSYNC) {
                flags.insert(.readSync)
            }
        #endif
        return flags
    }
}

extension WASIAbi.Timestamp {
    static func platformTimeSpec(
        atim: WASIAbi.Timestamp,
        mtim: WASIAbi.Timestamp,
        fstFlags: WASIAbi.FstFlags
    ) throws -> (access: Clock.TimeSpec, modification: Clock.TimeSpec) {
        return try (
            atim.platformTimeSpec(
                set: fstFlags.contains(.ATIM), now: fstFlags.contains(.ATIM_NOW)
            ),
            mtim.platformTimeSpec(
                set: fstFlags.contains(.MTIM), now: fstFlags.contains(.MTIM_NOW)
            )
        )
    }

    func platformTimeSpec(set: Bool, now: Bool) throws -> Clock.TimeSpec {
        switch (set, now) {
        case (true, true):
            throw WASIAbi.Errno.EINVAL
        case (true, false):
            return Clock.TimeSpec(
                seconds: Int(self / 1_000_000_000),
                nanoseconds: Int(self % 1_000_000_000)
            )
        case (false, true): return .now
        case (false, false): return .omit
        }
    }
}

extension WASIAbi.Filestat {
    init(stat: FileDescriptor.Attributes) {
        self = WASIAbi.Filestat(
            dev: WASIAbi.Device(stat.device),
            ino: WASIAbi.Inode(stat.inode),
            filetype: WASIAbi.FileType(platformFileType: stat.fileType),
            nlink: WASIAbi.LinkCount(stat.linkCount),
            size: WASIAbi.FileSize(stat.size),
            atim: WASIAbi.Timestamp(platformTimeSpec: stat.accessTime),
            mtim: WASIAbi.Timestamp(platformTimeSpec: stat.modificationTime),
            ctim: WASIAbi.Timestamp(platformTimeSpec: stat.creationTime)
        )
    }
}

extension WASIAbi.Timestamp {

    fileprivate init(seconds: Int, nanoseconds: Int) {
        self = UInt64(nanoseconds + seconds * 1_000_000_000)
    }

    init(platformTimeSpec timespec: Clock.TimeSpec) {
        self.init(seconds: timespec.rawValue.tv_sec, nanoseconds: timespec.rawValue.tv_nsec)
    }
}

extension WASIAbi.Errno {

    static func translatingPlatformErrno<R>(_ body: () throws -> R) throws -> R {
        do {
            return try body()
        } catch let errno as Errno {
            guard let error = WASIAbi.Errno(platformErrno: errno) else {
                throw WASIError(description: "Unknown underlying OS error: \(errno)")
            }
            throw error
        }
    }

    init?(platformErrno: SystemPackage.Errno) {
        switch platformErrno {
        case .permissionDenied: self = .EPERM
        case .notPermitted: self = .EPERM
        case .noSuchFileOrDirectory: self = .ENOENT
        case .noSuchProcess: self = .ESRCH
        case .interrupted: self = .EINTR
        case .ioError: self = .EIO
        case .noSuchAddressOrDevice: self = .ENXIO
        case .argListTooLong: self = .E2BIG
        case .execFormatError: self = .ENOEXEC
        case .badFileDescriptor: self = .EBADF
        case .noChildProcess: self = .ECHILD
        case .deadlock: self = .EDEADLK
        case .noMemory: self = .ENOMEM
        case .permissionDenied: self = .EACCES
        case .badAddress: self = .EFAULT
        case .resourceBusy: self = .EBUSY
        case .fileExists: self = .EEXIST
        case .improperLink: self = .EXDEV
        case .operationNotSupportedByDevice: self = .ENODEV
        case .notDirectory: self = .ENOTDIR
        case .isDirectory: self = .EISDIR
        case .invalidArgument: self = .EINVAL
        case .tooManyOpenFilesInSystem: self = .ENFILE
        case .tooManyOpenFiles: self = .EMFILE
        case .inappropriateIOCTLForDevice: self = .ENOTTY
        case .textFileBusy: self = .ETXTBSY
        case .fileTooLarge: self = .EFBIG
        case .noSpace: self = .ENOSPC
        case .illegalSeek: self = .ESPIPE
        case .readOnlyFileSystem: self = .EROFS
        case .tooManyLinks: self = .EMLINK
        case .brokenPipe: self = .EPIPE
        case .outOfDomain: self = .EDOM
        case .outOfRange: self = .ERANGE
        case .resourceTemporarilyUnavailable: self = .EAGAIN
        case .nowInProgress: self = .EINPROGRESS
        case .alreadyInProcess: self = .EALREADY
        case .notSocket: self = .ENOTSOCK
        case .addressRequired: self = .EDESTADDRREQ
        case .messageTooLong: self = .EMSGSIZE
        case .protocolWrongTypeForSocket: self = .EPROTOTYPE
        case .protocolNotAvailable: self = .ENOPROTOOPT
        case .protocolNotSupported: self = .EPROTONOSUPPORT
        case .notSupported: self = .ENOTSUP
        case .addressFamilyNotSupported: self = .EAFNOSUPPORT
        case .addressInUse: self = .EADDRINUSE
        case .addressNotAvailable: self = .EADDRNOTAVAIL
        case .networkDown: self = .ENETDOWN
        case .networkUnreachable: self = .ENETUNREACH
        case .networkReset: self = .ENETRESET
        case .connectionAbort: self = .ECONNABORTED
        case .connectionReset: self = .ECONNRESET
        case .noBufferSpace: self = .ENOBUFS
        case .socketIsConnected: self = .EISCONN
        case .socketNotConnected: self = .ENOTCONN
        case .timedOut: self = .ETIMEDOUT
        case .connectionRefused: self = .ECONNREFUSED
        case .tooManySymbolicLinkLevels: self = .ELOOP
        case .fileNameTooLong: self = .ENAMETOOLONG
        case .noRouteToHost: self = .EHOSTUNREACH
        case .directoryNotEmpty: self = .ENOTEMPTY
        case .diskQuotaExceeded: self = .EDQUOT
        case .staleNFSFileHandle: self = .ESTALE
        case .noLocks: self = .ENOLCK
        case .noFunction: self = .ENOSYS
        case .overflow: self = .EOVERFLOW
        case .canceled: self = .ECANCELED
        case .identifierRemoved: self = .EIDRM
        case .noMessage: self = .ENOMSG
        case .illegalByteSequence: self = .EILSEQ
        case .badMessage: self = .EBADMSG
        case .multiHop: self = .EMULTIHOP
        case .noLink: self = .ENOLINK
        case .protocolError: self = .EPROTO
        case .notRecoverable: self = .ENOTRECOVERABLE
        case .previousOwnerDied: self = .EOWNERDEAD
        default: return nil
        }
    }
}
