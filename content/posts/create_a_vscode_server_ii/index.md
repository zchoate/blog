---
title: "Run a VSCode server on a Linode VPS: Part II"
description: "Setup up a Terraform project to provision a Linode server and host OpenVSCode Server with Docker Compose."
date: 2022-01-26T22:22:15-05:00
draft: false
tags: 
toc: true
showReadingTime: true
---
## We did a little bit of Terraform. Now for a little bit of Docker-Compose.
In the [last post](../create_a_vscode_server), we covered setting up the infrastructure required to run a simple OpenVSCode server deployment. If you're landing here and could care less about setting up a server in the cloud or using Terraform, that's fine. This covers the bits around getting OpenVSCode running in a Docker-Compose deployment. I'm assuming you at least have a Linux server with Docker and Docker-Compose installed.

## Docker-Compose Setup
I’ll preface this section by saying this is an MVP setup. I’ll probably refine my setup with an identity-aware proxy to leverage OpenID Connect. However, this setup should work and is somewhat secured with digest authentication and a token required for OpenVSCode Server.

### Prepare Files and Directories
I’ve prepared a script that can take care of this and some of the other prerequisites. The script is below, and we’ll break it down below that.
```bash
#!/bin/bash

# Set the following as environment variables:
# IDE_SECRET - token used for openvscode server
# IDE_USER - username for digest authentication
# IDE_REALM - realm for digest authentication - just set as traefik if not sure
# IDE_PASSWORD - plain text password to use for digest authentication

# Create ide user
adduser ide --home /home/ide --uid 1000 --disabled-password --system

# Create the IDE workspace directory
mkdir /home/ide/workspace

# Create the LetsEncrypt directory
mkdir /home/ide/.letsencrypt

# Echo the secret into the text file - can only contain 0-9,a-z,A-Z,-
echo $IDE_SECRET > /home/ide/.idesecret

# Create digest auth entry
new_pass=$(printf "%s:%s:%s" "$IDE_USER" "$IDE_REALM" "$IDE_PASSWORD" | md5sum | awk '{print $1}' )
echo "$IDE_USER:$IDE_REALM:$new_pass" > /home/ide/.ideusers

# Set ownership of directory to IDE user
chown -R ide /home/ide
```
- Add a user: We're creating a user named `ide` and a home directory for that user. This user won't login, so we don't need a password for it.
- Create a workspace directory: This will be used as the primary directory for OpenVSCode Server.
- Create `.letsencrypt` directory: This will be where LetsEncrypt certificates get saved.
- Create `.idesecret`: You'll need to export `IDE_SECRET` before running this script. This will be the token that is appended to the end of the URL to access the server `https://.../?tkn=IDE_SECRET_VALUE`.
- Create `.ideusers`: Before running this script, you'll need to export `IDE_USER`,`IDE_REALM`,`IDE_PASSWORD`. This is the Digest Authentication file used by Traefik for authenticating users before accessing the OpenVSCode Server instance. Anyone will be able to hit this, so make sure the password is significantly complex.
- Change the ownership of `/home/ide`: This should be owned by `ide` already but these new files created are likely owned by `root`. Let's make sure we get everything consistent.

### DNS
Make sure you have a DNS record pointed at your VPS IP. This should be done well before starting up the Docker containers since Traefik will leverage LetsEncrypt to issue a certificate. LetsEncrypt needs to resolve the hostname of the server before issuing the certificate.

### Docker-Compose
Here is the `docker-compose.yml` and I'll break it down below that.
```yaml
# /home/ide/docker-compose.yml

version: "3"

services:
  proxy:
    image: traefik:latest
    container_name: traefik
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /home/ide/.letsencrypt:/letsencrypt
      - /home/ide/.ideusers:/.ideusers:ro
    command:
      - --providers.docker=true
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.cn.acme.tlschallenge=true
      - --certificatesresolvers.cn.acme.email={{your_email_here}}
      - --certificatesresolvers.cn.acme.storage=/letsencrypt/acme.json
    ports:
      - 80:80
      - 443:443
      
  ide:
    image: gitpod/openvscode-server:latest
    container_name: ide
    command: --connection-secret /.idesecret
    user: 1000:1000
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /home/ide/workspace:/home/workspace
      - /home/ide/.idesecret:/.idesecret:ro
    labels:
      - traefik.enable=true
      - traefik.http.routers.ide.rule=Host(`{{your_hostname_here}}`)
      - traefik.http.routers.ide.entrypoints=web
      - traefik.http.routers.idetls.rule=Host(`{{your_hostname_here}}`)
      - traefik.http.routers.idetls.entrypoints=websecure
      - traefik.http.routers.idetls.tls.certresolver=cn
      - traefik.http.middlewares.ide-redirect.redirectscheme.scheme=https
      - traefik.http.middlewares.ide-redirect.redirectscheme.permanent=true
      - traefik.http.routers.ide.middlewares=ide-redirect@docker
      - traefik.http.middlewares.ide.digestauth.usersfile=/.ideusers
      - treafik.http.routers.idetls.middlewares=ide@docker
```
- Proxy
    - We're using Traefik as the reverse proxy. Traefik is also doing TLS termination.
    - Volumes
        - `/var/run/docker.sock` - For basic functionality in Traefik, we need to mount the Docker Unix socket - we'll do this as read-only, though. There are alternative methods that are more secure, but assuming your server is pretty secure, this is the easiest to get started.
        - `/home/ide/.letsencrypt` - For LetsEncrypt, we need to persist the certificates and related files, and we're doing that in the `.letsencrypt` directory created in the last step.
        - `/home/ide/.ideusers` - For the Digest Auth, we need to mount the `.ideusers` file we created in the last step.
    - Commands
        - `--providers.docker=true` - We’re telling Traefik that we’re running this in Docker. Kubernetes and other orchestrators are options as well.
        - `--entrypoints.web/websecure.address=:80/:443` - These are the ports we’re exposing on the outside of our proxy (HTTP and HTTPS)
        - `--certificateresolvers.cn.acme...` - These are the settings for LetsEncrypt. We could change the challenge type, but we’ll need to specify different values. Refer to Traefik’s documentation if you’re interested in doing DNS validation.
    - Ports
        - We're exposing 80 and 443 for HTTP and HTTPS traffic. We could also expose 8080 along with a command flag to enable the Traefik dashboard.
- IDE
    - This is the OpenVSCode Server container/configuration.
    - Commands
        - `--connection-secret /.idesecret` - A token is required for the OpenVSCode server. To keep this value consistent, we’re running this command to have the application reference this file for the token value.
    - User
        - This is set to the UID of the user created earlier. Running in this context makes permissions easier to manage since this container will be modifying files in a specific directory.
    - Volumes
        - `/etc/localtime` - Passing the time through.
        - `/home/ide/workspace` - This is the `home` directory of the application. Files created and modified will live in this directory.
        - `/home/ide/.idesecret` - This is the token file we're passing into OpenVSCode server.
    - Labels
        - Point to a hostname
            - ``traefik.http.routers.xxx.rule=Host(`hostname`)``
        - Point to an entrypoint/port
            - HTTP - `traefik.http.routers.ide.entrypoints=web`
            - HTTPS - `traefik.http.routers.idetls.entrypoints=websecure`
        - Enable TLS and ACME/LetsEncrypt
            - `traefik.http.routers.idetls.tls.certresolver=cn`
        - HTTP to HTTPS Redirect Middleware
            - `traefik.http.middlewares.ide-redirect.redirectscheme.scheme=https`
            - `traefik.http.middlewares.ide-redirect.redirectscheme.permanent=true`
        - DIgest Auth Middleware
            - `traefik.http.middlewares.ide.digestauth.usersfile=/.ideusers`
        - Tell a router to use a specific middleware
            - `traefik.http.routers.ide.middlewares=ide-redirect@docker`
            - `traefik.http.routers.idetls.middlewares=ide@docker`

Once the `docker-compose.yml` file is created, we can start the containers using `docker-compose up`. If I haven't tested the setup before, I prefer to run without the `-d` flag so I can see the logs directly in the console. Once everything starts up, navigate to the configured host with the `/?tkn={{vscode_token_value_here}}` appended to your hostname. You should be prompted to login with the username and password configured and then passed to the OpenVSCode page. If the token was incorrect or not added to the URL, you should see a `Forbidden` error on the page. Once you have successfully connected to the OpenVSCode page, you should be able to navigate there without passing the token since a cookie should be saved to your browser that is good for one week.

From here, you can hit `CTRL`+`C` on your SSH session and run `docker-compose up -d` to run detached. To stop the containers, run `docker-compose down` from the same `/home/ide` directory or you'll need to specify the path to the `docker-compose.yml` file.

That's it! This two-part post is my first attempt at putting together some technical content to share some of what I've been doing at home and professionally. If you notice an issue or see something incorrect, you can open a [Github issue](https://github.com/zchoate/blog/issues/new/choose).