This document describes the development environment for my webtrees project.


# Requirements

This project requires the following software to be installed:

* docker
* docker compose
* git
* bash

In addition, some variables must be defined and prerequisites must be met for the project.


# Setup
* After cloning the repository from `git@github.com:magicsunday/webtrees-docker.git` simply run the setup script::

```shell
./scripts/setup.sh
```

* This script will create the `.env` file for you and will ask you for the necessary variables.
    * If you run this project on your own host or a local machine, you can define the credentials by yourself.

* Adjust the settings in the `.env` file to your needs

* Start the containers using `make up`

# Buildbox
Use `make bash` to open a bash inside the build box as the configured user.


# Sonstiges
## Docker
Um Docker als nicht root-Benutzer ausführen zu können, ist es erforderlich den Benutzer zur "docker"-Gruppe hinzuzufügen.

Hierzu bitte auch https://docs.docker.com/engine/security/#docker-daemon-attack-surface lesen, hinsichtlich möglicher sicherheitsrelevanter Auswirkungen.

* Create the docker group if it does not exist
```shell
sudo groupadd docker
```  
* Add your user to the docker group
```shell
sudo usermod -aG docker $USER
```
* Benutzer abmelden und neu anmelden
* Überprüfung ob Gruppe gesetzt ist
```shell
groups
```

## Lokale Docker-Registry
Beim Verwendung meiner lokalen Docker-Registry (192.168.178.25:5000) kam es zum Fehler:

    Error response from daemon: Get https://192.168.178.25:5000/v2/: http: server gave HTTP response to HTTPS client

Um den Zugriff auch über HTTP zu erlauben, muss die Datei

    /etc/docker/daemon.json

angepasst werden. Hier muss im JSON folgender Eintrag hinzugefügt werden:

```json
{
    ...

    "insecure-registries": [
        "http://192.168.178.25:5000"
    ]
}
```

anschließend noch ein Neustart des Docker Dämons:

```shell
sudo service docker restart
```

