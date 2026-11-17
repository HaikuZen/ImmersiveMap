// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The WASI functions a Swift WebAssembly module imports, answered for a
// page, which has no files and no arguments: the standard output and error
// go to the console line by line, the clocks and the random bytes are the
// page's, the environment is the page's choice, and files the page fetched
// before starting the module can be read (the engine's resources,
// Web/map/), in a folder mounted at a path, the root by default, so the
// folders above them exist: FoundationEssentials' `createDirectory`
// climbs to the first folder that exists and never ends when none does.
// Nothing can be written. Everything else says the call is not supported
// (ENOSYS) or names no file (EBADF). The same module runs in Node.

const success = 0;
const badFile = 8;
const exists = 20;
const isDirectory = 31;
const invalid = 28;
const noEntry = 44;
const notSupported = 52;
const notDirectory = 54;
const readOnly = 69;

// WASI's file types.
const directoryType = 3;
const regularFileType = 4;
// The first descriptor after the standard three: the folder.
const folderDescriptor = 3;

export class WASIShim {
    /// - print: where a line of the module's output or error goes.
    /// - environment: the variables the module reads, name to value.
    /// - folder: the readable folder, `{ path, files }`, `files` a map of
    ///   the file's path in the folder (`resources/atlas.json`) to its
    ///   bytes (a Uint8Array), the folders on the way there too.
    constructor({
        print = (stream, line) => (stream === 2 ? console.error(line) : console.log(line)),
        environment = {},
        folder = { path: '/', files: new Map() },
    } = {}) {
        this.print = print;
        this.environment = Object.entries(environment).map(([name, value]) => new TextEncoder().encode(`${name}=${value}\0`));
        this.folder = folder;
        // The open descriptors past the folder's: { name, offset }, a null
        // name for the folder itself.
        this.open = new Map();
        this.nextDescriptor = folderDescriptor + 1;
        this.memory = null;
        this.pending = new Map();
        this.decoder = new TextDecoder();
    }

    /// Gives the shim the module's memory, once it is instantiated.
    bind(instance) {
        this.memory = instance.exports.memory;
    }

    view() {
        return new DataView(this.memory.buffer);
    }

    write(stream, bytes) {
        const text = (this.pending.get(stream) ?? '') + this.decoder.decode(bytes, { stream: true });
        const lines = text.split('\n');
        this.pending.set(stream, lines.pop());
        for (const line of lines) this.print(stream, line);
    }

    get imports() {
        const shim = this;
        const none = () => notSupported;
        const zeroCounts = (countPointer, sizePointer) => {
            shim.view().setUint32(countPointer, 0, true);
            shim.view().setUint32(sizePointer, 0, true);
            return success;
        };
        const environmentCounts = (countPointer, sizePointer) => {
            shim.view().setUint32(countPointer, shim.environment.length, true);
            shim.view().setUint32(sizePointer, shim.environment.reduce((sum, bytes) => sum + bytes.length, 0), true);
            return success;
        };
        const functions = {
            args_get: () => success,
            args_sizes_get: zeroCounts,
            environ_get(pointers, buffer) {
                const view = shim.view();
                let offset = buffer;
                shim.environment.forEach((bytes, index) => {
                    view.setUint32(pointers + index * 4, offset, true);
                    new Uint8Array(shim.memory.buffer, offset, bytes.length).set(bytes);
                    offset += bytes.length;
                });
                return success;
            },
            environ_sizes_get: environmentCounts,
            ...shim.folderFunctions(),
            clock_res_get(_id, resolutionPointer) {
                shim.view().setBigUint64(resolutionPointer, 1000n, true);
                return success;
            },
            clock_time_get(id, _precision, timePointer) {
                const nanoseconds = id === 0
                    ? BigInt(Date.now()) * 1000000n
                    : BigInt(Math.round(performance.now() * 1e6));
                shim.view().setBigUint64(timePointer, nanoseconds, true);
                return success;
            },
            fd_write(fd, vectors, count, writtenPointer) {
                if (fd !== 1 && fd !== 2) return badFile;
                const view = shim.view();
                let written = 0;
                for (let index = 0; index < count; index += 1) {
                    const pointer = view.getUint32(vectors + index * 8, true);
                    const length = view.getUint32(vectors + index * 8 + 4, true);
                    shim.write(fd, new Uint8Array(shim.memory.buffer, pointer, length));
                    written += length;
                }
                view.setUint32(writtenPointer, written, true);
                return success;
            },
            fd_fdstat_get(fd, statPointer) {
                const entry = shim.entry(fd);
                if (fd > 2 && entry === undefined) return badFile;
                const view = shim.view();
                // A character device, the folder or one of its files, no
                // flags, every right.
                view.setUint8(statPointer, fd <= 2 ? 2 : entry.name === null ? directoryType : regularFileType);
                view.setUint16(statPointer + 2, 0, true);
                view.setBigUint64(statPointer + 8, 0xffffffffffffffffn, true);
                view.setBigUint64(statPointer + 16, 0xffffffffffffffffn, true);
                return success;
            },
            random_get(pointer, length) {
                const bytes = new Uint8Array(shim.memory.buffer, pointer, length);
                for (let offset = 0; offset < length; offset += 65536) {
                    crypto.getRandomValues(bytes.subarray(offset, Math.min(offset + 65536, length)));
                }
                return success;
            },
            proc_exit(code) {
                throw new Error(`The module exited with ${code}`);
            },
        };
        return {
            wasi_snapshot_preview1: new Proxy(functions, {
                get: (target, name) => target[name] ?? none,
            }),
        };
    }

    /// The descriptor's entry: the mounted folder's, a folder's in it (a
    /// null name, `folder` its path) or an open file's, undefined for none.
    entry(fd) {
        if (fd === folderDescriptor) return { name: null, folder: '', offset: 0 };
        return this.open.get(fd);
    }

    /// A path in the folder as a file's name: "" for the folder itself,
    /// null for a path that leaves it.
    static nameInFolder(path) {
        const parts = path.split('/').filter((part) => part !== '' && part !== '.');
        if (parts.some((part) => part === '..')) return null;
        return parts.join('/');
    }

    /// Whether the path in the folder is a folder: the folder itself or one
    /// on the way to a file.
    isFolder(name) {
        if (name === '') return true;
        for (const path of this.folder.files.keys()) {
            if (path.startsWith(`${name}/`)) return true;
        }
        return false;
    }

    /// Writes a WASI filestat for a folder (a null file) or a file.
    writeStat(pointer, bytes) {
        const view = this.view();
        new Uint8Array(this.memory.buffer, pointer, 64).fill(0);
        view.setUint8(pointer + 16, bytes ? regularFileType : directoryType);
        view.setBigUint64(pointer + 24, 1n, true);
        view.setBigUint64(pointer + 32, BigInt(bytes ? bytes.length : 0), true);
    }

    readString(pointer, length) {
        return this.decoder.decode(new Uint8Array(this.memory.buffer, pointer, length).slice());
    }

    /// Reads from the bytes at the offset into the vectors, and returns
    /// the count read.
    readInto(bytes, offset, vectors, count) {
        const view = this.view();
        let read = 0;
        for (let index = 0; index < count; index += 1) {
            const pointer = view.getUint32(vectors + index * 8, true);
            const length = view.getUint32(vectors + index * 8 + 4, true);
            const chunk = bytes.subarray(Math.min(offset + read, bytes.length), Math.min(offset + read + length, bytes.length));
            new Uint8Array(this.memory.buffer, pointer, chunk.length).set(chunk);
            read += chunk.length;
            if (chunk.length < length) break;
        }
        return read;
    }

    /// The calls that read the folder: found by the C library at start
    /// (`fd_prestat_get`), then opened, read, sought and closed.
    folderFunctions() {
        const shim = this;
        const file = (fd) => {
            const entry = shim.entry(fd);
            if (entry === undefined) return { error: badFile };
            if (entry.name === null) return { error: isDirectory };
            return { entry, bytes: shim.folder.files.get(entry.name) };
        };
        // A path from a folder's descriptor as a path in the mounted
        // folder, or the error.
        const resolve = (fd, pointer, length) => {
            const entry = shim.entry(fd);
            if (entry === undefined) return badFile;
            if (entry.name !== null) return notDirectory;
            const name = WASIShim.nameInFolder(`${entry.folder}/${shim.readString(pointer, length)}`);
            return name === null ? noEntry : name;
        };
        return {
            fd_prestat_get(fd, pointer) {
                if (fd !== folderDescriptor) return badFile;
                const view = shim.view();
                view.setUint8(pointer, 0);
                view.setUint32(pointer + 4, new TextEncoder().encode(shim.folder.path).length, true);
                return success;
            },
            fd_prestat_dir_name(fd, pointer, length) {
                if (fd !== folderDescriptor) return badFile;
                const bytes = new TextEncoder().encode(shim.folder.path).subarray(0, length);
                new Uint8Array(shim.memory.buffer, pointer, bytes.length).set(bytes);
                return success;
            },
            path_open(fd, _dirflags, pathPointer, pathLength, openFlags, _rights, _inheritedRights, _fdflags, descriptorPointer) {
                const name = resolve(fd, pathPointer, pathLength);
                if (typeof name === 'number') return name;
                const isFolder = shim.isFolder(name);
                const isFile = shim.folder.files.has(name);
                // Creating: the folder is read only.
                if (openFlags & 1) return isFolder || isFile ? (openFlags & 4 ? exists : readOnly) : readOnly;
                if (openFlags & 8) return readOnly;
                if (!isFolder && !isFile) return noEntry;
                // O_DIRECTORY on a file.
                if (!isFolder && (openFlags & 2)) return notDirectory;
                const descriptor = shim.nextDescriptor;
                shim.nextDescriptor += 1;
                shim.open.set(descriptor, isFolder ? { name: null, folder: name, offset: 0 } : { name, offset: 0 });
                shim.view().setUint32(descriptorPointer, descriptor, true);
                return success;
            },
            path_filestat_get(fd, _flags, pathPointer, pathLength, statPointer) {
                const name = resolve(fd, pathPointer, pathLength);
                if (typeof name === 'number') return name;
                if (shim.isFolder(name)) {
                    shim.writeStat(statPointer, null);
                } else if (shim.folder.files.has(name)) {
                    shim.writeStat(statPointer, shim.folder.files.get(name));
                } else {
                    return noEntry;
                }
                return success;
            },
            fd_filestat_get(fd, statPointer) {
                const entry = shim.entry(fd);
                if (entry === undefined) return badFile;
                shim.writeStat(statPointer, entry.name === null ? null : shim.folder.files.get(entry.name));
                return success;
            },
            fd_read(fd, vectors, count, readPointer) {
                const { error, entry, bytes } = file(fd);
                if (error) return error;
                const read = shim.readInto(bytes, entry.offset, vectors, count);
                entry.offset += read;
                shim.view().setUint32(readPointer, read, true);
                return success;
            },
            fd_pread(fd, vectors, count, offset, readPointer) {
                const { error, bytes } = file(fd);
                if (error) return error;
                shim.view().setUint32(readPointer, shim.readInto(bytes, Number(offset), vectors, count), true);
                return success;
            },
            fd_seek(fd, offset, whence, positionPointer) {
                const { error, entry, bytes } = file(fd);
                if (error) return error;
                const base = whence === 0 ? 0 : whence === 1 ? entry.offset : bytes.length;
                const position = base + Number(offset);
                if (position < 0) return invalid;
                entry.offset = position;
                shim.view().setBigUint64(positionPointer, BigInt(position), true);
                return success;
            },
            fd_tell(fd, positionPointer) {
                const { error, entry } = file(fd);
                if (error) return error;
                shim.view().setBigUint64(positionPointer, BigInt(entry.offset), true);
                return success;
            },
            fd_close(fd) {
                return shim.open.delete(fd) ? success : badFile;
            },
        };
    }
}
