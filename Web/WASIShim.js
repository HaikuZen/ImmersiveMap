// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The WASI functions a Swift WebAssembly module imports, answered for a
// page, which has no files, no arguments and no environment: the standard
// output and error go to the console line by line, the clocks and the
// random bytes are the page's, and everything else says the call is not
// supported (ENOSYS) or names no file (EBADF). Enough for the engine's
// module, which reads no file in a browser. The same module runs in Node.

const success = 0;
const badFile = 8;
const notSupported = 52;

export class WASIShim {
    /// - print: where a line of the module's output or error goes.
    constructor({ print = (stream, line) => (stream === 2 ? console.error(line) : console.log(line)) } = {}) {
        this.print = print;
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
        const functions = {
            args_get: () => success,
            args_sizes_get: zeroCounts,
            environ_get: () => success,
            environ_sizes_get: zeroCounts,
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
                if (fd > 2) return badFile;
                const view = shim.view();
                // A character device, no flags, every right.
                view.setUint8(statPointer, 2);
                view.setUint16(statPointer + 2, 0, true);
                view.setBigUint64(statPointer + 8, 0xffffffffffffffffn, true);
                view.setBigUint64(statPointer + 16, 0xffffffffffffffffn, true);
                return success;
            },
            fd_prestat_get: () => badFile,
            fd_close: () => badFile,
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
}
