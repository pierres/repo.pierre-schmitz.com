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
build:
    pkgctl build -c "{{ invocation_directory() }}"

# Rebuild pacakge from current directory and increment its pkgrel
rebuild:
    pkgctl rebuild -c "{{ invocation_directory() }}"

# Update package from current directory to the given pkgver
update pkgver:
    pkgctl build -c --pkgver="{{ pkgver }}" "{{ invocation_directory() }}"

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

    mkdir -p "src/{{ repository }}"
    bsdtar xf "$tmpfile" --strip-components=1 --exclude='.SRCINFO' --exclude='.git*' -C 'src/{{ repository }}/{{ package }}'

    rm -f "$tmpfile"

update-all-from-aur:
    #!/usr/bin/env fish
    for repo in src/*
        for pkg in $repo/*
            set -l pkg_name (path basename "$pkg")
            set -l aur_version (curl --fail --silent --show-error "https://aur.archlinux.org/rpc/v5/info/$pkg_name" | jq --raw-output '.results[0].Version')

            if test "$aur_version" = "null"
                #echo "Package not found in the AUR: $pkg_name"
                continue
            end

            pushd $pkg

            set -l pkg_version (makepkg --printsrcinfo | string match -rg '^\s*pkg(?:ver|rel)\s*=\s*(.+)\s*$' | string join '-')

            if test (vercmp $pkg_version $aur_version) -lt 0
                echo "Updating package: $pkg_name from $pkg_version to $aur_version"
                just update-from-aur
            else
                #echo "Package already up to date or newer: $pkg_name"
            end

            popd
        end
    end

# Release package from current directory
release:
    #!/usr/bin/env fish
    if not test -f '{{ invocation_directory() }}/PKGBUILD'
        echo 'No PKGBUILD was found!'
        return 1
    end

    set -l repo (path basename (path resolve '{{ invocation_directory() }}/../'))
    set -l dist_dir "dist/$repo/os/{{ CARCH }}"

    mkdir -p "$dist_dir"

    set -l dist_files

    set -l pkg_files (bash -c 'pushd {{ invocation_directory() }} >/dev/null && makepkg --packagelist')

    for pkg_file in $pkg_files
        set -l pkg_file_name (path basename $pkg_file)

        if string match -- '*-debug-*' "$pkg_file_name"
            echo "Skipping debug package $pkg_file_name"
            continue
        end

        if not test -f "$pkg_file"
            echo "package file $pkg_file_name not found"
            return 1
        end

        if not test -f "$pkg_file".sig
            echo "package signature file $pkg_file_name.sig not found"
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

# Remover package from current directory; keeps the source directory
[confirm]
remove:
    #!/usr/bin/env fish
    if not test -f '{{ invocation_directory() }}/PKGBUILD'
        echo 'No PKGBUILD was found!'
        return 1
    end

    set -l repo (path basename (path resolve '{{ invocation_directory() }}/../'))
    set -l dist_dir "dist/$repo/os/{{ CARCH }}"

    set -l dist_files

    set -l pkg_files (bash -c 'pushd {{ invocation_directory() }} >/dev/null && makepkg --packagelist')
    set -l pkg_names (bash -c 'pushd {{ invocation_directory() }} >/dev/null && makepkg --printsrcinfo' | string match -rg '^\s*pkgname\s*=\s*(.+)\s*$')

    for pkg_file in $pkg_files
        set -l pkg_file_name (path basename $pkg_file)

        if string match -- '*-debug-*' "$pkg_file_name"
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
