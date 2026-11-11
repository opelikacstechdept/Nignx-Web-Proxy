# Updater: keeps every Docker Compose app on the server in step with GitHub (see update-apps.sh)
FROM docker:27.5.1-cli
# git (included in the base image) fetches the config from GitHub
COPY --chmod=755 update-apps.sh /usr/local/bin/update-apps.sh
ENTRYPOINT ["/usr/local/bin/update-apps.sh"]
