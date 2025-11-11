#!/bin/bash
set -e

DOTFILES_REPO=https://codeberg.org/janw/dotfiles.git
CONFIGURE_FISH_AS_DEFAULT_SHELL=true

PACKAGE_PPAS=(
    ppa:fish-shell/release-4
)

PACKAGE_LIST=(
    fish
)

USERNAME="${USERNAME:-"automatic"}"
MARKER_FILE="/usr/local/etc/janw-devcontainer-features/sanity"

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Must be run as root.'
    exit 1
fi

FEATURE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

export DEBIAN_FRONTEND=noninteractive

# Debian / Ubuntu packages
install_debian_packages() {
    apt-get update -y
    apt-get install -y --no-install-recommends software-properties-common
    for ppa in "${PACKAGE_PPAS[@]}"; do
        add-apt-repository -y "$ppa"
    done

    apt-get update -y
    apt-get install -y --no-install-recommends \
        ${PACKAGE_LIST[@]} \
        2> >( grep -v 'debconf: delaying package configuration, since apt-utils is not installed' >&2 )

    # Clean up
    apt-get clean -y
    rm -rf /var/lib/apt/lists/*
}

# Load markers to see which steps have already run
if [ -f "${MARKER_FILE}" ]; then
    echo "Marker file found:"
    cat "${MARKER_FILE}"
    source "${MARKER_FILE}"
fi

if [ "${PACKAGES_ALREADY_INSTALLED:-}" != "true" ]; then
    install_debian_packages
fi


# If in automatic mode, determine if a user already exists, if not use vscode
if [ "${USERNAME}" = "auto" ] || [ "${USERNAME}" = "automatic" ]; then
    if [ "${_REMOTE_USER}" != "root" ]; then
        USERNAME="${_REMOTE_USER}"
    else
        USERNAME=""
        POSSIBLE_USERS=("devcontainer" "vscode" "node" "codespace" "$(awk -v val=1000 -F ":" '$3==val{print $1}' /etc/passwd)")
        for CURRENT_USER in "${POSSIBLE_USERS[@]}"; do
            if id -u ${CURRENT_USER} > /dev/null 2>&1; then
                USERNAME=${CURRENT_USER}
                break
            fi
        done
        if [ "${USERNAME}" = "" ]; then
            USERNAME=vscode
        fi
    fi
    if id -u ${USERNAME} > /dev/null 2>&1; then
        GROUP_NAME="$(id -gn $USERNAME)"
    fi
elif [ "${USERNAME}" = "none" ]; then
    USERNAME=root
    GROUP_NAME="${USERNAME}"
fi


if [ "${USERNAME}" = "root" ]; then
    user_home="/root"
else
    user_home="/home/${USERNAME}"
fi

if [ "${DOTFILES_ALREADY_INSTALLED}" != "true" ]; then
    dotfiles_dir="$user_home/.dotfiles"
    if [ ! -d "$dotfiles_dir" ]; then
        git clone "$DOTFILES_REPO" "$dotfiles_dir"

        cd "$dotfiles_dir"
        ./install
    fi
    DOTFILES_ALREADY_INSTALLED="true"
fi

if [ "${CONFIGURE_FISH_AS_DEFAULT_SHELL}" == "true" ]; then
    # Fixing chsh always asking for a password on alpine linux
    # ref: https://askubuntu.com/questions/812420/chsh-always-asking-a-password-and-get-pam-authentication-failure.
    if [ ! -f "/etc/pam.d/chsh" ] || ! grep -Eq '^auth(.*)pam_rootok\.so$' /etc/pam.d/chsh; then
        echo "auth sufficient pam_rootok.so" >> /etc/pam.d/chsh
    elif [[ -n "$(awk '/^auth(.*)pam_rootok\.so$/ && !/^auth[[:blank:]]+sufficient[[:blank:]]+pam_rootok\.so$/' /etc/pam.d/chsh)" ]]; then
        awk '/^auth(.*)pam_rootok\.so$/ { $2 = "sufficient" } { print }' /etc/pam.d/chsh > /tmp/chsh.tmp && mv /tmp/chsh.tmp /etc/pam.d/chsh
    fi

    chsh --shell /usr/bin/fish ${USERNAME}
fi

# Adapted, simplified inline Oh My Zsh! install steps that adds, defaults to a codespaces theme.
# See https://github.com/ohmyzsh/ohmyzsh/blob/master/tools/install.sh for official script.
if [ "${INSTALL_OH_MY_ZSH}" = "true" ]; then
    user_rc_file="${user_home}/.zshrc"
    oh_my_install_dir="${user_home}/.oh-my-zsh"
    template_path="${oh_my_install_dir}/templates/zshrc.zsh-template"
    if [ ! -d "${oh_my_install_dir}" ]; then
        umask g-w,o-w
        mkdir -p ${oh_my_install_dir}
        git clone --depth=1 \
            -c core.eol=lf \
            -c core.autocrlf=false \
            -c fsck.zeroPaddedFilemode=ignore \
            -c fetch.fsck.zeroPaddedFilemode=ignore \
            -c receive.fsck.zeroPaddedFilemode=ignore \
            "https://github.com/ohmyzsh/ohmyzsh" "${oh_my_install_dir}" 2>&1

        # Shrink git while still enabling updates
        cd "${oh_my_install_dir}"
        git repack -a -d -f --depth=1 --window=1
    fi

    # Add Dev Containers theme
    mkdir -p ${oh_my_install_dir}/custom/themes
    cp -f "${FEATURE_DIR}/scripts/devcontainers.zsh-theme" "${oh_my_install_dir}/custom/themes/devcontainers.zsh-theme"
    ln -sf "${oh_my_install_dir}/custom/themes/devcontainers.zsh-theme" "${oh_my_install_dir}/custom/themes/codespaces.zsh-theme"

    # Add devcontainer .zshrc template
    if [ "$INSTALL_OH_MY_ZSH_CONFIG" = "true" ]; then
        if ! [ -f "${template_path}" ] || ! grep -qF "$(head -n 1 "${template_path}")" "${user_rc_file}"; then
            echo -e "$(cat "${template_path}")\nzstyle ':omz:update' mode disabled" > ${user_rc_file}
        fi
        sed -i -e 's/ZSH_THEME=.*/ZSH_THEME="devcontainers"/g' ${user_rc_file}
    fi

    # Copy to non-root user if one is specified
    if [ "${USERNAME}" != "root" ]; then
        copy_to_user_files=("${oh_my_install_dir}")
        [ -f "$user_rc_file" ] && copy_to_user_files+=("$user_rc_file")
        cp -rf "${copy_to_user_files[@]}" /root
        chown -R ${USERNAME}:${GROUP_NAME} "${copy_to_user_files[@]}"
    fi
fi

# Write marker file
MARKER_DIR="$(dirname "${MARKER_FILE}")"
if [ ! -d "$MARKER_DIR" ]; then
    mkdir -p "$MARKER_DIR"
fi
cat >"${MARKER_FILE}"<<EOF
PACKAGES_ALREADY_INSTALLED=${PACKAGES_ALREADY_INSTALLED}
DOTFILES_ALREADY_INSTALLED=${DOTFILES_ALREADY_INSTALLED}
EOF

echo "Done!"
