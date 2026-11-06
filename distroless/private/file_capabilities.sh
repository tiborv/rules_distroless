#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

# Resolve action-relative paths before entering the private scratch directory.
absolute() {
    case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$PWD" "$1" ;; esac
}
bsdtar=$(absolute "$1")
coreutils=$(absolute "$2")
package=$(absolute "$3")
out=$(absolute "$4")
path=$5
shift 5

tmp=$("$coreutils" mktemp -d)
trap '"$coreutils" rm -rf "$tmp"' EXIT

# bsdtar matches archive names as patterns; quote metacharacters literally.
pattern=${path//\\/\\\\}
pattern=${pattern//\*/\\*}
pattern=${pattern//\?/\\?}
pattern=${pattern//\[/\\[}
entry=$("$bsdtar" -tf "$package" -- "$pattern")
printf -v entry '%b' "$entry"
if [[ ${entry#./} != "$path" ]]; then
    printf 'Expected exactly one archive member: %s\n' "$path" >&2
    exit 1
fi
listing=$("$bsdtar" -tvf "$package" -- "$pattern")
if [[ $listing != -* ]]; then
    printf 'Expected a regular file: %s\n' "$path" >&2
    exit 1
fi

# Never extract archive paths onto the host filesystem.
"$bsdtar" -xOf "$package" -- "$pattern" > "$tmp/content"
cd "$tmp"
printf '#mtree\n./file type=file uid=0 gid=0 time=0 mode=0755 content=content\n' > file.mtree
"$bsdtar" --format=ustar -cf payload.tar @file.mtree

# bsdtar's CLI cannot assign xattrs. Emit only a PAX metadata header ourselves;
# bsdtar handles the file's data and regular-file header. A fixed short payload
# name prevents an intervening PAX header from replacing this metadata.
pax_prefix() {
    local size=$(( ${#1} + $2 + 4 )) next
    while :; do
        next=$(( ${#size} + ${#1} + $2 + 3 ))
        [[ $size == "$next" ]] && break
        size=$next
    done
    printf '%s %s=' "$size" "$1"
}
write_pax() {
    local LC_ALL=C
    pax_prefix path "${#path}"
    printf '%s\n' "$path"
    pax_prefix SCHILY.xattr.security.capability "$#"
    for byte in "$@"; do
        printf -v octal '\\%03o' "$byte"
        printf '%b' "$octal"
    done
    printf '\n'
}
write_pax "$@" > pax
size=$("$coreutils" wc -c < pax)

# All header strings are fixed ASCII without spaces. NUL-pad the fields, then
# compute the checksum with its eight bytes treated as spaces (8 * 32).
printf '%-100s%07o\000%07o\000%07o\000%011o\000%011o\000%8s%s%100sustar\00000%32s%32s%07o\000%07o\000%155s%12s' \
    PaxHeaders/capabilities 420 0 0 "$size" 0 '' x '' '' '' 0 0 '' '' |
    "$coreutils" tr ' ' '\000' > header
checksum=256
for byte in $("$coreutils" od -An -tu1 -v header); do
    checksum=$((checksum + byte))
done
printf '%06o\000 ' "$checksum" |
    "$coreutils" dd of=header bs=1 seek=148 conv=notrunc status=none
"$coreutils" truncate -s "$(( (size + 511) / 512 * 512 ))" pax
"$coreutils" cat header pax payload.tar > "$out"
