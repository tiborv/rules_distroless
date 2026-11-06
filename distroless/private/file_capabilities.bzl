"""File capability overlays without running package installation scripts."""

load(":tar.bzl", "tar_lib")

# Bit positions from Linux include/uapi/linux/capability.h (through Linux 6.12).
_CAPABILITIES = [
    "chown",
    "dac_override",
    "dac_read_search",
    "fowner",
    "fsetid",
    "kill",
    "setgid",
    "setuid",
    "setpcap",
    "linux_immutable",
    "net_bind_service",
    "net_broadcast",
    "net_admin",
    "net_raw",
    "ipc_lock",
    "ipc_owner",
    "sys_module",
    "sys_rawio",
    "sys_chroot",
    "sys_ptrace",
    "sys_pacct",
    "sys_admin",
    "sys_boot",
    "sys_nice",
    "sys_resource",
    "sys_time",
    "sys_tty_config",
    "mknod",
    "lease",
    "audit_write",
    "audit_control",
    "setfcap",
    "mac_override",
    "mac_admin",
    "syslog",
    "wake_alarm",
    "block_suspend",
    "audit_read",
    "perfmon",
    "bpf",
    "checkpoint_restore",
]

def _file_capabilities_impl(ctx):
    path = ctx.attr.path
    if not path or path.startswith("/") or any([p in ["", ".", ".."] for p in path.split("/")]) or any([c in path for c in ["\n", "\r", "\000"]]):
        fail("path must be normalized, relative, and contain no NUL or line breaks")
    if not ctx.attr.capabilities:
        fail("capabilities must not be empty")

    # Linux VFS revision 2: effective flag, then two little-endian pairs of
    # permitted/inheritable 32-bit words. Only permitted/effective are set.
    value = [1, 0, 0, 2] + [0] * 16
    for capability in {c: None for c in ctx.attr.capabilities}:
        if not capability.startswith("cap_") or capability[4:] not in _CAPABILITIES:
            fail("unknown capability: " + capability)
        bit = _CAPABILITIES.index(capability[4:])
        offset = 4 + bit // 8 + (4 if bit >= 32 else 0)
        value[offset] += [1, 2, 4, 8, 16, 32, 64, 128][bit % 8]

    bsdtar = ctx.toolchains[tar_lib.TOOLCHAIN_TYPE]
    coreutils = ctx.toolchains["@bazel_lib//lib:coreutils_toolchain_type"]
    output = ctx.actions.declare_file(ctx.label.name + ".tar")
    args = ctx.actions.args()
    args.add_all([
        bsdtar.tarinfo.binary,
        coreutils.coreutils_info.bin,
        ctx.file.package,
        output,
        path,
    ])
    args.add_all(value)
    ctx.actions.run_shell(
        command = 'source "$1" "${@:2}"',
        inputs = [ctx.file.package, ctx.file._script],
        outputs = [output],
        tools = [bsdtar.default.files, coreutils.default.files],
        arguments = [ctx.file._script.path, args],
        mnemonic = "FileCapabilities",
    )
    return [DefaultInfo(files = depset([output]))]

file_capabilities = rule(
    implementation = _file_capabilities_impl,
    doc = """Create a single-file layer with permitted and effective Linux capabilities.

Use after the package layer in `oci_image.tars`. This replaces a package's
`setcap ...+ep` installation step without running its maintainer scripts or
requiring root, Linux xattrs, or setcap on the build host. The selected member
must be a regular file; the output has mode 0755, uid/gid 0 and mtime 0.

```starlark
file_capabilities(
    name = "ping_capabilities",
    package = "@debian//iputils-ping:data",
    path = "usr/bin/ping",
    capabilities = ["cap_net_raw"],
)
```
""",
    attrs = {
        "package": attr.label(mandatory = True, allow_single_file = [".tar", ".tar.gz", ".tar.xz", ".tar.zst"]),
        "path": attr.string(mandatory = True, doc = "Relative path of the file in the package archive."),
        "capabilities": attr.string_list(mandatory = True, doc = "Linux capability names, e.g. cap_net_raw; sets permitted and effective bits."),
        "_script": attr.label(default = ":file_capabilities.sh", allow_single_file = True),
    },
    toolchains = [tar_lib.TOOLCHAIN_TYPE, "@bazel_lib//lib:coreutils_toolchain_type"],
)
