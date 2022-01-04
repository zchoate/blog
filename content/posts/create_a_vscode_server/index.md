---
title: "Run a VSCode server on a Linode VPS"
description: "Setup up a Terraform project to provision a Linode server and host OpenVSCode Server with Docker Compose."
date: 2022-01-02T22:22:15-05:00
draft: false
tags: 
toc: true
showReadingTime: true
---
## A little bit of Terraform, a little bit of Docker Compose
I was getting my setup ready for my MacBook Air so I could start my first post. I assumed that every modern computer was capable of driving 2 external displays, even a Raspberry Pi is capable of driving 2 displays. Anyways, I can't stand just having 1 display off and working slightly off center so I'll be getting my old ThinkPad running Pop_OS back out and working on that. I don't want to put anything on there I don't want to lose so I figured I'd finally take on a project I've been pushing off for a while - get a VSCode server or something similar running on a Linode VPS and just run VSCode in a browser. That way I can switch between the MacBook Air when I need something portable and use the ThinkPad when I need to use 2 displays like the monster Apple must think I am.

## Selecting a server to run
VSCode should be pretty simple since it is an Electron application and already has a web server component. Doing some research on this so changed my mind about how simple this decision is. There's [cdr/code-server](https://github.com/cdr/code-server), [GitPod's OpenVSCode-Server](https://github.com/gitpod-io/openvscode-server), in addition to the VSCode server implementation Microsoft has. Eclipse Theia is another option but seems to be a bit different from the other implementations. GitPod's implementation seems to be the best option since it is a critical part of GitPod's commerical offering but is also regularly synced with the upstream VSCode project. There's a readily available container so this seems to be a quick way to get started. Everything is going to be in Git so if for some reason I decide to switch to something else, I can just scrap this server and start with a new one and clone repos as needed. GitPod's open-source self-hosted solution offering more functionality sounds like a solid solution to try out in a Kubernetes cluster in the near future.

## Linode VPS setup
Obviously you can run Docker-Compose or whatever container orchestrator you prefer on whatever infrastructure you prefer. The goal for me is to have something that is accessible from the road as well as home and Linode is cheap, fast, and reliable. I'm also sitting about 1100 miles away from my home lab with most of it powered off. I'm going to start off with the $5/month instance and hope that's enough juice to run for just one user. I'll update this post if I end up needing to bumping this up (although if I do, I'll probably switch to running it out of my homelab).

I'm going to use Terraform as you might have guessed from the subheading. I'm going to leverage a **Stack script** to get the server setup with **docker** and **docker-compose**. I could probably try getting Ansible setup to do the configuration and ongoing management but I just going to stick with the simple **Stack script** for now.

So let's dive in…

### Linode API Token
To authenticate to Linode, we'll need to generate an API key with Linode. Once we have that we'll set that as an environment variable `LINODE_TOKEN`. This ensures we're not putting sensitive data in our code. Generate the Linode token by logging in to your Linode account, expanding the account section, and selecting *API Tokens*.
{{< imgsize alt="Linode Account Settings" src="static/linode_account.png" width="250" >}}
Then create a *Personal Access Token*. Give the token a descriptive name and determine your expiration date. Typically, I'd consider restricting the token as far as permissions go but since this will be what we use Terraform with, we'll need access to read/write most of the resources here so I would give it read/write permisson over all the options here. Save the key that gets generated somewhere. This is the equivalent of your credentials so protect it as such or you might have a higher than expected bill with a bunch of cryptomining servers. We'll get the token added to the environment in a bit.

Now that we've got the authentication piece figured out, let's start on the Terraform code...

### Provider
Use the provider's docs to get started and as a reference for new resources. Each provider will have a configuration block in your Terraform code, we can also specify the version. Refer to the [Linode Terraform provider](https://registry.terraform.io/providers/linode/linode/latest/docs) docs for an example of the provider configuration. This is what we have below:
``` terraform
// provider.tf
terraform {
  required_providers {
    linode = {
      source = "linode/linode"
      version = "1.25.0"
    }
  }
}

provider "linode" {
  # Configuration options
}
```
This should get us started with the provider. Save this as `provider.tf` in your project's root. 

### VPS
We've got our `provider` block specified in the `provider.tf` file. We could keep adding to that file but I find it easier to organize everything into individual files so I can reuse pieces later and it makes it a bit easier for someone new to pick it up and make changes. Let's start with the base Linux VPS on Linode. 
```terraform
// instance.tf
resource "linode_instance" "vps" {
    image           = var.vps_image
    label           = var.vps_label
    group           = var.vps_group
    region          = var.linode_region
    type            = var.vps_size
    authorized_keys = [var.ssh_pub]
}
```
So this by itself seems inefficent, but the idea is to not repeat yourself (DRY). We're going to define a set of common constraints and we'll use variables so we can differentiate between dev and production environments. I don't plan on creating a dev server but if I did, I just need to create a new set of variables. Going into these options, they're pretty self explanatory…
`image` is the image or operating system you'll be using for your VPS.
`label` is the name of the resource.
`group` is a way to just group resources within Linode.
`region` is the Linode datacenter/region to deploy to.
`type` is the size of the instance you'd like to deploy.
`authorized_keys` is your public SSH key to add to the root account.
There's one more field I want to add but first I want to get that resource added and we can see how to link resources together to create an implied dependency.

### Stack Script
```terraform
// script.tf
resource "linode_stackscript" "docker_compose" {
    label       = "dockercomposesetup"
    description = "Setup Docker and Docker-Compose"
    script      = file("dockercompose.sh")
    images      = [var.vps_image]
}
```
This is a pretty simple resource since we're just taking the `dockercompose.sh` file we'll create in a bit and uploading it as a Stack Script. Now we'll go back and modify the `instance.tf` to include running that Stack Script when provisioned. When we make this update, Terraform will see that the Stack Script is a dependency of the instance and will create the Stack Script first. This prevents us from needing to go in and add an explicit dependency using a `depends_on` block.
```terraform
// instance.tf
resource "linode_instance" "vps" {
    image           = var.vps_image
    label           = var.vps_label
    group           = var.vps_group
    region          = var.linode_region
    type            = var.vps_size
    authorized_keys = [var.ssh_pub]
    
    stackscript_id  = linode_stackscript.docker_compose.id
}
```
Use the Terraform provider docs to determine which attributes of a resource get exported. In this case, the ID of the Stack Script is exported and we can use that to link the Stack Script to the Instance.

The actual BASH script we'll use to get the server setup for Docker Compose:
```bash
#!/bin/bash
#
# Can be used as a Linode StackScript
#
# Install docker and docker-compose
sudo apt -q update
sudo apt install -q -y docker.io docker-compose git
sudo systemctl start docker
sudo systemctl enable docker

# Enable UFW and allow SSH, HTTP and HTTPS
sudo ufw allow ssh
sudo ufw allow http
sudo ufw allow https
sudo ufw enable && sudo ufw reload
```
This script just gets Docker, Docker-Compose, and Git installed on the server. Then we add rules for SSH, HTTP, and HTTPS traffic on UFW and enable UFW. Just have this script in the root of the Terraform project named `dockercompose.sh`.

### Firewall
```terraform
// firewall.tf
resource "linode_firewall" "vps" {
    label   = var.vps_label

    // http & https
    inbound {
        label       = "allow_http"
        action      = "ACCEPT"
        protocol    = "TCP"
        ports       = "80"
        ipv4        = ["0.0.0.0/0"]
        ipv6        = ["ff00::/8"]
    }
    inbound {
        label       = "allow_https"
        action      = "ACCEPT"
        protocol    = "TCP"
        ports       = "443"
        ipv4        = ["0.0.0.0/0"]
        ipv6        = ["ff00::/8"]
    }
    // ssh from home
    inbound {
        label       = "allow_ssh"
        action      = "ACCEPT"
        protocol    = "TCP"
        ports       = "22"
        ipv4        = [var.trusted_ip]
    }
    inbound_policy  = "DROP"

    outbound_policy = "ACCEPT"

    linodes = [linode_instance.vps.id]
}
```
This is pretty straightforward. We're creating an access control list for a set of ports and allowed source IPs. We are specifying a `trusted_ip`. I have a server that has Wireguard that I can put here, otherwise I would recommend using your home IP. This gets tricky if you don't have a somewhat consistent IP you are coming from (carrier-grade NAT). In that case I would get a VPN setup and use that IP. I'm hoping to have a guide on getting that setup on Linode as well. We'll associate the `linode_instance.vps.id` as the the target of this firewall.

### Variables
```terraform
// vars.tf
variable linode_region {}
variable vps_image {
    default = "linode/ubuntu20.04"
}
variable vps_label {
    default = "vps"
}
variable vps_group {
    default = "central-vps"
}
variable vps_size {
    default = "g6-nanode-1"
}
variable ssh_pub {}
variable trusted_ip {}
```
Another easy one. We're just declaring variables and setting default values. If you don't have a default value, you'll need to pass something. You can get fancy and start setting `null` as your default and do some conditional logic but I won't cover that here.

So that's the Terraform code. There's another file we need to specify but this isn't technically required. You can specify variables in the Terraform command, as environment values, or set default values for your variables.
```terraform
// prod.tfvars

linode_region    = "us-central"
```
I'm only going to set the `linode_region` here. I'll pass the `ssh_pub` and `trusted_ip` in as environment variables. If we want to change any of the default values from the default, we can add them in the `prod.tfvars` file, as an environment variable, or in the Terraform command.

### .gitignore
One more file that's pretty important if you're going to push this to a Git repo (which I would highly recommend) is the `.gitignore` file. This tells Git to ignore files and folders matching the patterns specified here. This is especially nice for Terraform since you don't want your state files to get synced up to Git and potentially leak sensitive information. The `tfvars` files would be included in this as well. I always inject sensitive values outside of the `tfvars` files anyways so I'll comment this out for myself. 
```
# Local .terraform directories
**/.terraform/*

# .tfstate files
*.tfstate
*.tfstate.*

# Crash log files
crash.log
crash.*.log

# Exclude all .tfvars files, which are likely to contain sentitive data, such as
# password, private keys, and other secrets. These should not be part of version
# control as they are data points which are potentially sensitive and subject
# to change depending on the environment.
#
# *.tfvars

# Ignore override files as they are usually used to override resources locally and so
# are not checked in
override.tf
override.tf.json
*_override.tf
*_override.tf.json

# Include override files you do wish to add to version control using negated pattern
#
# !example_override.tf

# Include tfplan files to ignore the plan output of command: terraform plan -out=tfplan
# example: \*tfplan\*

# Ignore CLI configuration files
.terraformrc
terraform.rc
```

### Terraform Init
Terraform needs to be initialized in a project directory before any other Terraform commands can be run. This will do a quick syntax check of your code as well as getting all the dependent pieces setup in your project folder. The command should look like the snippet below:
```bash
terraform init
```
And you should see the following output:
```
Initializing the backend...

Initializing provider plugins...
- Finding linode/linode versions matching "1.25.0"...
- Installing linode/linode v1.25.0...
- Installed linode/linode v1.25.0 (signed by a HashiCorp partner, key ID F4E6BBD0EA4FE463)

Partner and community providers are signed by their developers.
If you'd like to know more about provider signing, you can read about it here:
https://www.terraform.io/docs/cli/plugins/signing.html

Terraform has created a lock file .terraform.lock.hcl to record the provider
selections it made above. Include this file in your version control repository
so that Terraform can guarantee to make the same selections by default when
you run "terraform init" in the future.

Terraform has been successfully initialized!

You may now begin working with Terraform. Try running "terraform plan" to see
any changes that are required for your infrastructure. All Terraform commands
should now work.

If you ever set or change modules or backend configuration for Terraform,
rerun this command to reinitialize your working directory. If you forget, other
commands will detect it and remind you to do so if necessary.
```
### Terraform Plan
Now that the project has been intialized, we can run the Terraform Plan command. If you haven't already make sure any variables you're passing from the environment are exported. When you export variables to the environment, use `TF_VAR_` as the prefix to your variable name. Here are 2 examples below:
```bash
export TF_VAR_ssh_pub=(cat ~/.ssh/id_rsa.pub)
export TF_VAR_trusted_ip=1.1.1.1/32
```
Your Linode Token should be exported as `LINODE_TOKEN` with no prefix.

The command to run the Terraform Plan:
```bash
terraform plan -var-file=prod.tfvars
```
Here's what the output should look like:
```
Terraform used the selected providers to generate the following execution plan. Resource actions are indicated with the following symbols:
  + create

Terraform will perform the following actions:

  # linode_firewall.vps will be created
  + resource "linode_firewall" "vps" {
      + devices         = (known after apply)
      + disabled        = false
      + id              = (known after apply)
      + inbound_policy  = "DROP"
      + label           = "vps"
      + linodes         = (known after apply)
      + outbound_policy = "ACCEPT"
      + status          = (known after apply)

      + inbound {
          + action   = "ACCEPT"
          + ipv4     = [
              + "0.0.0.0/0",
            ]
          + ipv6     = [
              + "ff00::/8",
            ]
          + label    = "allow_http"
          + ports    = "80"
          + protocol = "TCP"
        }
      + inbound {
          + action   = "ACCEPT"
          + ipv4     = [
              + "0.0.0.0/0",
            ]
          + ipv6     = [
              + "ff00::/8",
            ]
          + label    = "allow_https"
          + ports    = "443"
          + protocol = "TCP"
        }
      + inbound {
          + action   = "ACCEPT"
          + ipv4     = [
              + "*.*.*.*/32",
            ]
          + label    = "allow_ssh"
          + ports    = "22"
          + protocol = "TCP"
        }
    }

  # linode_instance.vps will be created
  + resource "linode_instance" "vps" {
      + authorized_keys    = [
          + "ssh-rsa *****",
        ]
      + backups            = (known after apply)
      + backups_enabled    = (known after apply)
      + boot_config_label  = (known after apply)
      + group              = "central-vps"
      + id                 = (known after apply)
      + image              = "linode/ubuntu20.04"
      + ip_address         = (known after apply)
      + ipv4               = (known after apply)
      + ipv6               = (known after apply)
      + label              = "vps"
      + private_ip_address = (known after apply)
      + region             = "us-central"
      + specs              = (known after apply)
      + stackscript_id     = (known after apply)
      + status             = (known after apply)
      + swap_size          = (known after apply)
      + type               = "g6-nanode-1"
      + watchdog_enabled   = true

      + alerts {
          + cpu            = (known after apply)
          + io             = (known after apply)
          + network_in     = (known after apply)
          + network_out    = (known after apply)
          + transfer_quota = (known after apply)
        }
    }

  # linode_stackscript.docker_compose will be created
  + resource "linode_stackscript" "docker_compose" {
      + created             = (known after apply)
      + deployments_active  = (known after apply)
      + deployments_total   = (known after apply)
      + description         = "Setup Docker and Docker-Compose"
      + id                  = (known after apply)
      + images              = [
          + "linode/ubuntu20.04",
        ]
      + is_public           = false
      + label               = "dockercomposesetup"
      + script              = <<-EOT
            #!/bin/bash
            #
            # Can be used as a Linode StackScript
            #
            # Install docker and docker-compose
            sudo apt -q update
            sudo apt install -q -y docker.io docker-compose git
            sudo systemctl start docker
            sudo systemctl enable docker
            
            # Enable UFW and allow SSH, HTTP and HTTPS
            sudo ufw allow ssh
            sudo ufw allow http
            sudo ufw allow https
            sudo ufw enable && sudo ufw reload
        EOT
      + updated             = (known after apply)
      + user_defined_fields = (known after apply)
      + user_gravatar_id    = (known after apply)
      + username            = (known after apply)
    }

Plan: 3 to add, 0 to change, 0 to destroy.

──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't guarantee to take exactly these actions if you run "terraform apply"
now.
```
We can see that there were several resources that were _planned_ to be created. We've got the **firewall** resource first, then the **instance**, and the **stackscript**. If we're satisifed with the output we can run the `apply` command next. Another item to note is if you're running in CI/CD or want to run with no input on the `apply` command, use the `-out` option to save the _plan_ and refer to that file in the `apply` command. I won't cover that in this guide.

### Terraform Apply
This command is pretty similar to the `plan` command and actually performs a `plan` if no plan file is specified. Once the plan step is completed, you'll be prompted to review the output and confirm or decline the planned actions. Here's the command to run the apply:
```bash
terraform apply -var-file=prod.tfvars
```

And the output without the plan output:
```
Plan: 3 to add, 0 to change, 0 to destroy.

Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes

linode_stackscript.docker_compose: Creating...
linode_stackscript.docker_compose: Creation complete after 0s [id=xxxxx]
linode_instance.vps: Creating...
linode_instance.vps: Still creating... [10s elapsed]
linode_instance.vps: Still creating... [20s elapsed]
linode_instance.vps: Still creating... [30s elapsed]
linode_instance.vps: Still creating... [40s elapsed]
linode_instance.vps: Still creating... [50s elapsed]
linode_instance.vps: Creation complete after 59s [id=xxxxxxxx]
linode_firewall.vps: Creating...
linode_firewall.vps: Creation complete after 0s [id=xxxxx]

Apply complete! Resources: 3 added, 0 changed, 0 destroyed.
```
So once the `apply` is completed, we can move on to getting our Docker Compose config on the server for the OpenVSCode server.

## Docker-Compose Setup
I'll preface this section by saying this is an MVP setup. I'll probably refine my setup further with an identity-aware proxy to leverage OpenID Connect. However this setup should work and is somewhat secured with digest authentication and a token required for OpenVSCode Server. 

### Prepare Files and Directories
I've prepared a script that can take care of this as well as some of the other prequisites. The script is below and we'll break it down below that.
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
- Add a user… we're creating a user named `ide` and a home directory for that user. This user won't login so we don't need a password for it.
- Create a workspace directory… this will be used as the primary directory for OpenVSCode Server
- Create `.letsencrypt` directory… this will be where LetsEncrypt certificates get saved.
- Create `.idesecret`… you'll need to export `IDE_SECRET` prior to running this script. This will be the token that is appended to the end of the URL to access the server `https://.../?tkn=IDE_SECRET_VALUE`
- Create `.ideusers`… you'll need to export `IDE_USER`,`IDE_REALM`,`IDE_PASSWORD` prior to running this script. This is the Digest Authentication file used by Traefik for authenticating users prior to accessing the OpenVSCode Server instance. Anyone will be able to hit this so make sure the password is significantly complex.
- Change the ownership of `/home/ide`… this should be owned by `ide` already but these new files created are likely owned by `root`. Let's make sure we get everything consistent.

### DNS
Make sure you have a DNS record pointed at your VPS IP. This should be done well before we start up the Docker containers since Traefik will leverage LetsEncrypt to issue a certificate. LetsEncrypt need to resolve the hostname of the server prior to issuing the certificate.

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
        - `/var/run/docker.sock` - For basic functionality in Traefik, we need to mount the Docker Unix socket - we'll do this as read-only though. There are alternative methods that are more secure but this is the easiest to get started with assuming your server is pretty secure to start with.
        - `/home/ide/.letsencrypt` - For LetsEncrypt, we need to persist the certificates and related files and we're doing that in the `.letsencrypt` directory created in the last step.
        - `/home/ide/.ideusers` - For the Digest Auth, we need to mount the `.ideusers` file we created in the last step.
    - Commands
        - `--providers.docker=true` - We're telling Traefik that we're running this in Docker. Kubernetes and other orchestrators are options as well.
        - `--entrypoints.web/websecure.address=:80/:443` - These are the ports we're exposing on the outside of our proxy (HTTP and HTTPS)
        - `--certificateresolvers.cn.acme...` - These are the settings for LetsEncrypt. We could change the challenge type but we'll need to specify different values. Refer to Traefik's documenation if you're interested in doing DNS validation.
    - Ports
        - We're exposing 80 and 443 for HTTP and HTTPS traffic. We could also expose 8080 along with a command flag to enable the Traefik dashboard.
- IDE
    - This is the OpenVSCode Server container/configuration.
    - Commands
        - `--connection-secret /.idesecret` - A token is required for OpenVSCode server, to keep this value consistent, we're running this command to have the application reference this file for the token value.
    - User
        - This is set to the UID of the user created earlier. Running in this context makes permissions a bit easier to manage since this container will be modifying files in a specific directory.
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

Once the `docker-compose.yml` file is created, we can start the containers using `docker-compose up`. If I haven't tested the setup before, I prefer to run without the `-d` flag so I can see the logs directly in the console. Once everything starts up, navigate to the configured host with the `/?tkn={{vscode_token_value_here}}` appended to your hostname. You should be prompted to login with the username and password configured and then passed to the OpenVSCode page. If the token was incorrect or not added to the URL, then you should see a `Forbidden` error on the page. Once you have connected to the OpenVSCode page successfully, you should be able to navigate there without passing the token since a cookie should be saved to your browser that is good for 1 week.

From here you can hit `CTRL`+`C` on your SSH session and run `docker-compose up -d` to run detached. To stop the containers run `docker-compose down` from the same `/home/ide` directory or you'll need to specify the path to the `docker-compose.yml` file.