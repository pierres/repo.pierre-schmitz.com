set dotenv-load := true

SERVER_URL := env_var('SERVER_URL')
DB_EXT := '.db.tar.zst'
CARCH := arch()

# List all available recipes
[private]
default:
    @echo -e 'Configured for architecture \033[1m{{ CARCH }}\033[0m on server \033[1m{{ SERVER_URL }}\033[0m.\n'
    @just --list

# Remove any untracked files, excluding released packages
[confirm]
clean:
    git clean -ffdqx -e .idea -e .vscode -e dist -e .env
    git submodule foreach git clean -ffdqx

# Synchronize two directories
[private]
rsync source target *options:
    @rsync \
        --progress \
        --checksum \
        --recursive \
        --links \
        --safe-links \
        --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r \
        --rsh=ssh \
        --human-readable \
        --times \
        --delete-after \
        --one-file-system \
        --force \
        --delay-updates \
        --exclude={.gitkeep,*.db.*old*,*.files.*old*} \
        {{ options }} \
        '{{ source }}/' '{{ target }}'

# Upload packages to server
upload: (rsync 'dist' SERVER_URL '--delete-excluded')

# Download packages from server, overwriting any locally released packages
[confirm]
download: (rsync SERVER_URL 'dist')

# Build pacakge from current directory
[no-cd]
build:
    #!/usr/bin/env fish
    if not test -f 'PKGBUILD'
        echo 'No PKGBUILD was found!' >&2
        return 1
    end

    aur-x86_64-build -c

    if test -f .SRCINFO
        makepkg --printsrcinfo > .SRCINFO
    end

# Run nvchecker for the package from current directory
[no-cd]
check-version:
    #!/usr/bin/env fish
    if not test -f 'PKGBUILD'
        echo 'No PKGBUILD was found!' >&2
        return 1
    end
    pkgctl version check

# Run nvchecker for all packages
check-all-versions:
    #!/usr/bin/env fish
    pkgctl version check src/*/*

# Sign package from current directory
[no-cd]
[private]
sign:
    #!/usr/bin/env fish
    if not test -f 'PKGBUILD'
        echo 'No PKGBUILD was found!' >&2
        return 1
    end

    if not test -f "$HOME/.makepkg.conf"
        echo '~/.makepg.conf not found' >&2
        return 1
    end

    set -l gpg_key (bash -c 'source ~/.makepkg.conf && echo $GPGKEY')
    if test (string length "$gpg_key") -lt 10
        echo "No valid GPG key: $gpg_key" >&2
        return 1
    end

    set -l pkg_files (makepkg --packagelist)

    for pkg_file in $pkg_files
        set -l pkg_file_name (path basename $pkg_file)

        if string match -q -- '*-debug-*' "$pkg_file_name"
            echo "Skipping debug package $pkg_file_name"
            continue
        end

        if not test -f "$pkg_file"
            echo "package file $pkg_file_name not found" >&2
            return 1
        end

        gpg --detach-sign --use-agent --no-armor -u "$gpg_key" "$pkg_file"
    end

# Update package from current directory with the newest release from the AUR
update-from-aur:
    #!/usr/bin/env fish
    set -l package (path basename "{{ invocation_directory() }}")
    set -l repository (path basename (path resolve "{{ invocation_directory() }}/../"))
    just create-from-aur "$package" "$repository"

# Create a new package based on one from the AUR
create-from-aur package repository='aur':
    #!/usr/bin/env fish
    set -l tmpfile (mktemp -t create-from-aur.XXXXXXXXXX)
    trap "rm -f '$tmpfile'" EXIT INT

    curl --fail --silent --show-error 'https://aur.archlinux.org/cgit/aur.git/snapshot/{{ package }}.tar.gz' -o "$tmpfile" || exit 1

    mkdir -p "src/{{ repository }}/{{ package }}"
    bsdtar xf "$tmpfile" --strip-components=1 --exclude='.SRCINFO' --exclude='.git*' --exclude='.nvchecker.toml' -C 'src/{{ repository }}/{{ package }}'

    rm -f "$tmpfile"

    echo -e "[{{ package }}]\nsource = 'aur'" > "src/{{ repository }}/{{ package }}/.nvchecker.toml"

# Release package from current directory
[no-cd]
release: sign
    #!/usr/bin/env fish
    if not test -f 'PKGBUILD'
        echo 'No PKGBUILD was found!' >&2
        return 1
    end

    set -l repo (path basename (path resolve '../'))
    set -l dist_dir (path resolve "{{ justfile_directory() }}/dist/$repo/os/{{ CARCH }}")

    mkdir -p "$dist_dir"

    set -l dist_files

    set -l pkg_files (makepkg --packagelist)

    for pkg_file in $pkg_files
        set -l pkg_file_name (path basename $pkg_file)

        if string match -q -- '*-debug-*' "$pkg_file_name"
            echo "Skipping debug package $pkg_file_name"
            continue
        end

        if not test -f "$pkg_file"
            echo "package file $pkg_file_name not found" >&2
            return 1
        end

        if not test -f "$pkg_file".sig
            echo "package signature file $pkg_file_name.sig not found" >&2
            return 1
        end

        if not pacman-key -v "$pkg_file".sig
            return 1
        end

        cp -a "$pkg_file"{,.sig} "$dist_dir"

        set -a dist_files "$dist_dir/$pkg_file_name"
    end

    repo-add \
        --remove \
        --prevent-downgrade \
        --new \
        --sign \
        --verify \
        --include-sigs \
        "$dist_dir/$repo{{ DB_EXT }}" \
        $dist_files

# Remove package from current directory; keeps the source directory
[confirm]
[no-cd]
remove:
    #!/usr/bin/env fish
    if not test -f 'PKGBUILD'
        echo 'No PKGBUILD was found!' >&2
        return 1
    end

    set -l repo (path basename (path resolve '../'))
    set -l dist_dir (path resolve "{{ justfile_directory() }}/dist/$repo/os/{{ CARCH }}")

    set -l dist_files

    set -l pkg_files (makepkg --packagelist)
    set -l pkg_names (makepkg --printsrcinfo | string match -rg '^\s*pkgname\s*=\s*(.+)\s*$')

    for pkg_file in $pkg_files
        set -l pkg_file_name (path basename $pkg_file)

        if string match -q -- '*-debug-*' "$pkg_file_name"
            echo "Skipping debug package $pkg_file_name"
            continue
        end

        set -a dist_files "$dist_dir/$pkg_file_name"
    end

    repo-remove \
        --sign \
        --verify \
        "$dist_dir/$repo{{ DB_EXT }}" \
        $pkg_names

    rm -f $dist_files{,.sig}
