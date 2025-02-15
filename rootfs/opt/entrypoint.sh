#!/usr/bin/env bash

set -e # Instructs a shell to exit if a command fails, i.e., if it outputs a non-zero exit status.
set -u # Treats unset or undefined variables as an error when substituting (during parameter expansion).
set -m # Displays a message when a task completes.

if [ -z "${LOCAL_GROUP_NAME}" ]; then
    LOCAL_GROUP_NAME='www-data'
fi

if [ -z "${LOCAL_GROUP_ID}" ]; then
    LOCAL_GROUP_ID=82
fi

if [ -z "${LOCAL_USER_NAME}" ]; then
    LOCAL_USER_NAME=user
fi

if [ -z "${LOCAL_USER_ID}" ]; then
    LOCAL_USER_ID=1001
fi

echo -e "\033[0;32m ✔\033[0m Create user ${LOCAL_USER_NAME} (${LOCAL_USER_ID}) within group ${LOCAL_GROUP_NAME} (${LOCAL_GROUP_ID})"

# Create the group
groupadd -r "${LOCAL_GROUP_NAME}" -g "${LOCAL_GROUP_ID}" >/dev/null 2>&1 || true

# Create the user
useradd --no-log-init --create-home -u "${LOCAL_USER_ID}" -g "${LOCAL_GROUP_NAME}" -s /bin/bash -d "/home/${LOCAL_USER_NAME}" "${LOCAL_USER_NAME}" >/dev/null 2>&1 || true

HOME_DIR="/home/${LOCAL_USER_NAME}"
FILE_PROFILE="${HOME_DIR}/.bashrc"

# Copy mounted .ssh files to the users ssh files
cp -r /root/.ssh "${HOME_DIR}" && chown "${LOCAL_USER_NAME}" -R "${HOME_DIR}"/.ssh

# Export all current env variables expecting HOME, otherwise after doing su the user still would have /root as home dir
export | grep -v HOME >>"${FILE_PROFILE}"

# Add the required commands to the users .profile file:
# - change dir to current working dir
# - if the command is not "bash", add the command
# - add a logout after command has been executed
echo -e "cd $PWD" >>"${FILE_PROFILE}"

if [ -n "${APP_DIR}" ]; then
    APP_BIN="/var/www/html/app/vendor/bin"
fi

echo -e "export PATH=\"${APP_BIN}:/root/.composer/vendor/bin:\$HOME/.composer/vendor/bin:\$HOME/bin:\$PATH\"" >>"${FILE_PROFILE}"
chown "${LOCAL_USER_NAME}:${LOCAL_GROUP_NAME}" -R "${HOME_DIR}"
chown "${LOCAL_USER_NAME}" "$PWD"

# Switch the user and execute shell or command as user
su "${LOCAL_USER_NAME}" -s /bin/bash -c "$@"
