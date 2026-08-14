# DietPi setup

This is a diary of my journey into hosting my own stuff on a raspberry pi 4b.  
So it never gets forgotten... Especially by myself, 4 months from now, when
I'll ask myself how or why I did something.  

Table of contents:  
<!-- vim-markdown-toc GFM -->

- [Introduction](#introduction)
- [First boot: tui configuration](#first-boot-tui-configuration)
- [Second boot: we're actually home](#second-boot-were-actually-home)
    - [Basic config](#basic-config)
        - [Turn off leds](#turn-off-leds)
    - [ssh](#ssh)
    - [ufw](#ufw)
    - [fail2ban](#fail2ban)
    - [nginx](#nginx)
        - [Configure fail2ban](#configure-fail2ban)
        - [Self signed certificate](#self-signed-certificate)
        - [certbot](#certbot)
        - [ddclient](#ddclient)
    - [PiHole](#pihole)
        - [DHCP](#dhcp)
        - [Manage blocklists](#manage-blocklists)
    - [Vaultwarden](#vaultwarden)
    - [Ruby on rails application](#ruby-on-rails-application)
        - [Phusion Passenger](#phusion-passenger)
        - [rbenv](#rbenv)
        - [Configure logrotate](#configure-logrotate)
        - [Configure fail2ban](#configure-fail2ban-1)
        - [Tweaks to reduce IO](#tweaks-to-reduce-io)
- [For the daring: cloud backups](#for-the-daring-cloud-backups)
    - [Configure rclone](#configure-rclone)
    - [The backup itself](#the-backup-itself)

<!-- vim-markdown-toc -->



## Introduction

This is a collection of documentation and useful scripts to set up a DietPi
server with as less disk usage as possible while still offering certain 
services such as pihole, public static pages and so forth.  

It is advised to use a SanDisk 64GB MAX ENDURANCE card or equivalent.  



## First boot: tui configuration

On the first boot after flashing the image you'll be greeted by a tui to setup
a few things:  
 - set a static local ip address  
 - select software to install via software center:  
    - openssh (replace dropbear)  
    - nginx  
    - fail2ban  
 - set openssh as default ssh server  
 - set locale/timezone/keymap  
 - advanced options:  
    - ensure there is no swap set (we'll add in zram soon enough)  



## Second boot: we're actually home



### Basic config

You'll most likely want to install these:  
 - `sudo apt update`  
 - `sudo apt install zsh vim rsync git ncdu`  

Then you should enable zram. You may argue you won't use enough ram to justify
the hassle, but it's always handy to have:  
 - `sudo /boot/dietpi/func/dietpi-set_swapfile 1 zram`  



#### Turn off leds

I'm not a fan of the power led (the red one) being always on, so I decided to
turn it off and only keep the activity (green) one. To do so:  
```sh
echo "
### MINE BELOW
###############################################################################

# Disable the ACT LED.
#dtparam=act_led_trigger=none
#dtparam=act_led_activelow=off

# Disable the PWR LED.
dtparam=pwr_led_trigger=none
dtparam=pwr_led_activelow=off/boot
" | sudo tee -a /boot/firmware/config.txt
```



### ssh

First off let's take care of the dietpi's user:  
 - add add ssh authorized keys to the dietpi user:  
    - `mkdir /home/dietpi/.ssh`  
    - `echo "YOURKEY" > /home/dietpi/.ssh/authorized_keys`  
 - generate ssh key for the dietpi user:  
    - `ssh-keygen -t ed25519`  

Then let's harden the ssh server:  
  - `sudo vim /etc/ssh/sshd_config`  
     - set a non-standard port  
     - set `PermitRootLogin no`  
     - set `PasswordAuthentication no`  
     - set `UsePAM no`  
  - `sudo systemctl restart sshd`  

**NOTE**: if you want to access your device from the outside world, remember to
make the router forward the right ssh port to the pi.  



### ufw

Ufw is mandatory if we want to keep any service at all in here:  
 - `sudo apt install ufw`  

Then create a rules file for what we're probably gonna use.  
**NOTE**: be sure to set the right ssh port!!  
```sh
echo '[dietpi nginx]
title = dietpi nginx
description = nginx http (80) and https (443)
ports = 80,443/tcp

[dietpi pihole dns]
title = dietpi pihhole dns
description = pihole dns (53)
ports = 53/tcp|53/udp

[dietpi pihole dhcp]
title = dietpi pihole dhcp
description = pihole dhcp (67)
ports = 67/udp

[dietpi ssh]
title = dietpi ssh
description = ssh
ports = 22/tcp
' | sudo tee /etc/ufw/applications.d/my-dietpi
```

Enable what you may need:  
 - ssh from anywhere:  
    -`sudo ufw allow "dietpi ssh"`  
 - http/https from anywhere:  
    - `sudo ufw allow dietpi nginx"`  
 - pihole dns from local network only:  
    - `sudo ufw allow from 192.168.1.0/24 to any app "dietpi pihole dns"`  
 - pihole dhcp has to be from anywhere:
    - `sudo ufw allow from any to any app "dietpi pihole dhcp"`  



### fail2ban

Disable dropbear jail as we use ssh:  
 - `sudo  sed -i 's,\[dropbear\],#\[dropbear\],g' jail.conf`  

To easily check jails and ban/unban ip, check `scripts/fail2ban-quick`:  
 - `fail2ban-quick`: a simple list of all active jails  
 - `fail2ban-quick -b/-u IP`: bans/unbans the given ip  

Actual custom jails and filters will be described in the programs' sections at
need.  



### nginx

You may wonder why we're bothering with nginx.  
Well, no matter if you're just gonna install pi-hole, it's better to configure
it all now so it'll be server under a specific location, so it won't be a pain
to change it later on.  

Refer to the `nginx` folder, as it contains both samples on how to configure
subroutes for pihole as well as a good starting point for ssl security
headers.  

First off setup dhparam:  
 - `sudo openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048`  

Then you'll want to increase the number of worker connections in
`/etc/nginx/nginx.conf`, as the default (50) is not much:  
```nginx
events
{
  worker_connections 1024;
}
```

**NOTE**: as with ssh, if you want nginx to be accessible from the outside
world you'll need to make the router forward ports 80 and 443 to the pi.  

**NOTE**: if you're planning to have both a public website with less sensitive
services exposed along with a private one, you may want to take a look at
`nginx/sites-available` as a starting point.  



#### Configure fail2ban

I advise to add a custom rule to make fail2ban catch every 4XX error, so we can
block crawlers and what not easily:  
```sh
echo '[Definition]

failregex = ^<HOST> - .*" 4[0-9][0-9] .*
' | sudo tee /etc/fail2ban/filter.d/nginx-4xx.conf
```

Now we can add jails using it to our nginx log. As an example:  
```sh
echo '[nginx-public]
enabled = true
backend = auto
port = 40,443
filter = nginx-4xx
logpath = /var/log/nginx/public_access.log
# Max 3 attempts every 30 minutes with a 1 day ban.
maxretry = 3
findtime = 1800
bantime = 1d
' | sudo tee /etc/fail2ban/jail.d/nginx-public.local

echo '[nginx-private]
enabled = true
backend = auto
port = 40,443
filter = nginx-4xx
logpath = /var/log/nginx/private_access.log
# Max 3 attempts every 30 minutes with a 1 day ban.
maxretry = 3
findtime = 1800
bantime = 1d
' | sudo tee /etc/fail2ban/jail.d/nginx-private.local
```



#### Self signed certificate

Now... Generating self signed certificates is not easy not fast.  
I advise you to look to an in-depth guide.  



#### certbot

Cerbot is definitely needed if we want to expose a website to the rest of the
world.  
You can skip this section otherwise.  

**NOTE** before moving forward you have to make sure that:  
 - nginx is working  
 - your router forwards port 80 to your pi, and nginx catches it  
 - you have a valid DNS record pointing to your router  

Install certbot: `sudo apt install certbot`  

Create a certificate for your domain:  
 - `sudo certbot certonly --cert-name "your-cert-name" -d domain.foo.org -v`  
 - I advise to pick the "go through nginx" option  

At this point... I'm aware there are default systemd services and timers to
renew the certificates, but PTSD forces me to make my own:  
```sh
echo 'certbot-renew.service
[Unit]
Description=Renew letsencrypt certificates
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/certbot renew --force-renewal --preferred-chain "ISRG Root X1" --post-hook "systemctl restart nginx"
' | sudo tee /etc/systemd/system/certbot-renew.service

echo '[Unit]
Description=Renew letsencrypt certificates

[Timer]
OnCalendar=Mon *-*-* 00:04:00
Persistent=true

[Install]
WantedBy=timers.target
' | sudo tee /etc/systemd/system/certbot-renew.timer
```

Now all that's left to do is to enable the timer:  
 - `sudo systemctl daemon-reload`  
 - `sudo systemctl enable --now certbot-renew.service`  



#### ddclient

If you're using a dynamic dns service you definitely want to setup ddclient to
keep it up to date:  
 - `sudo apt install ddclient`  
 - the installation process guides you through the configuration  
 - once done edit `/etc/ddclient.conf` and remove every '\' at the end of each
   line, as they break everything.  

To see if it all works, run:  
 - `ddclient -daemon=0 -debug -verbose -noquiet`  

Enable the systemd service to make it work:  
 - `systemctl enable --now ddclient.service`  



### PiHole

We're gonna serve pihole under nginx's /pihole location. You can refer to
`nginx/sites-available/private.conf`.  

The installation process is a little convoluted, as we need to free up port 80
for the installer to work, then we need to make pihole's webapp use a different
port that we can then serve through nginx. Plus, we need to set the correct
subroute we'll serve it under:  
 - `sudo systemctl stop nginx`  
 - `sudo dietpi-software install 93`  
 - `sudo pihole-FTL --config webserver.port "9017"`  
 - `sudo pihole-FTL --config webserver.paths.prefix "/pihole"`  
 - `sudo pihole setpassword`  
 - `sudo systemctl start nginx`  

#### DHCP

To use PiHole's dhcp server, be sure to:  
 - configure PiHole's dhcp via webui, as it's quite easier:
   https://192.168.XXX.XXX/pihole/admin/settings/dhcp  
 - disable your router's own dhcp server  

#### Manage blocklists

You should probably take a look at https://hagezi-mirror.dnsbunker.org and add
at least the pro blocklist.  
The management page is at https://192.168.XXX.XXX/pihole/admin/groups/lists .  



### Vaultwarden

Installed via the software center:   
 - `sudo dietpi-software install 183`  

Everything is stored in `/mnt/dietpi_userdata/vaultwarden`.  

Now, a few notes:  
 - I advise against serving /admin to the world, keep it to your local
   network  
 - we're gonna serve vaultwarden under a subroute, but for peace of mind please
   do not use /vaultwarden, use a harder to guess location  

Now, what you need to do is:  
 - `sudo systemctl stop vaultwarden`  
 - generate an admin token via:  
    - `echo -n 'your awesome password' | argon2 "$(openssl rand -base64 32)" -e -id -k 65540 -t 3 -p 4`  
 - edit `/mnt/dietpi_userdata/vaultwarden/vaultwarden.env`:  
    - set `DOMAIN='https://your.dns/vaultwarden'`  
    - set `WEB_VAULT_ENABLED=true`  
    - set `SIGNUPS_ALLOWED=false`  
    - set `ADMIN_TOKEN='the token you generated before'`  
- edit `/mnt/dietpi_userdata/vaultwarden/config.json`:  
   - set `"domain": "https://your.dns/vaultwarden",`  
   - set `"sso_callback_path": "https://your.dns/vaultwarden/identity/connect/oidc-signin",`  
   - set `"admin_token": "'the token you generated before",`  

We can now finally restart vaultwarden:  
 - `sudo systemctl enable --now vaultwarden`  



### Ruby on rails application

Why not? This is mostyl a reminder for myself :p  



#### Phusion Passenger

Passenger is available for arm64, so installation is quite straightforward:  
 - `sudo apt install dirmngr gnupg apt-transport-https ca-certificates curl`  
 - `curl https://oss-binaries.phusionpassenger.com/auto-software-signing-gpg-key-2025.txt | gpg --dearmor | sudo tee /etc/apt/keyrings/phusion.gpg >/dev/null`  
 - `sudo chmod 644 /etc/apt/keyrings/phusion.gpg`  
 - `echo "deb [signed-by=/etc/apt/keyrings/phusion.gpg] https://oss-binaries.phusionpassenger.com/apt/passenger trixie main" | sudo tee /etc/apt/sources.list.d/passenger.list`  
 - `sudo chmod 644 /etc/apt/sources.list.d/passenger.list`  
 - `sudo apt update`  
 - `sudo apt-get install libnginx-mod-http-passenger`  



#### rbenv

This is quite easy to set up, we just need to download two repos and fix their
permissions:  
 - `sudo apt install ruby-build build-essential libssl-dev libyaml-dev shared-mime-info`  
 - `cd /opt`  
 - `sudo git clone https://github.com/rbenv/rbenv.git`  
 - `cd rbenv`  
 - `sudo mkdir plugins`  
 - `cd plugins`  
 - `sudo git clone https://github.com/rbenv/ruby-build.git`  
 - `sudo find /opt/rbenv -type f -exec chmod a+r '{}' \;`  
 - `sudo find /opt/rbenv -type d -exec chmod a+r,a+x '{}' \;`  
 - `sudo find /opt/rbenv -iwholename '*/bin/*' -type f -exec chmod a+x '{}' \;`  
 - `sudo find /opt/rbenv -iwholename '*/libexec/*' -type f -exec chmod a+x '{}' \;`  

Then we can add global settings for every user:  
```sh
 echo '# System-wide rbenv setup:
export RUBY_CONFIGURE_OPTS=--disable-install-doc
export GLOB_RBENV=/opt/rbenv
export RBENV_ROOT=${HOME}/.rbenv
export PATH="${GLOB_RBENV}/bin:${GLOB_RBENV}/plugins/ruby-build/bin:${HOME}/.rbenv/shims:${HOME}/.gem/bin:${PATH}"
eval "$(rbenv init -)"
' | sudo tee /etc/profile.d/rbenv.sh
```

And set the right permissions:  
 - `sudo chmod 644 /etc/profile.d/rbenv.sh`  



#### Configure logrotate

Set logrotate to only keep 1 week of logs, 1 day per file:  
```sh
echo '/mnt/dietpi_userdata/rails_*/log/*.log {
  daily
  missingok
  rotate 7
  compress
  delaycompress
  notifempty
  copytruncate
}
' | sudo tee /etc/logrotate.d/rails
```



#### Configure fail2ban

If everything is set correctly, nginx will already catch the 4xx errors that
rails reports.  

If you use custom logs you may need to add a relevant filter and jail.  



#### Tweaks to reduce IO

We can reduce IO by moving the `tmp` and `log` folders into tmpfs:  
```sh
echo "
# Rails tmpfs:
tmpfs /mnt/dietpi_userdata/rails_application/log tmpfs defaults,size=100M,noatime,nodev,nosuid,uid=1001,gid=1001,mode=750 0 0
tmpfs /mnt/dietpi_userdata/rails_application/tmp tmpfs defaults,size=200M,noatime,nodev,nosuid,uid=1001,gid=1001,mode=750 0 0
" | sudo tee -a /etc/fstab
```

Afterwards we need to make systemd aware of the changes:  
 - `sudo systemctl daemon-reload`  
 - `sudo mount -a`  


However, if you had fail2ban monitor the log files in there it'll break on
reboot because `log` will be empty. To avoid that we can add a service at boot
to create it anew:   
```sh
echo "[Unit]
Description=Create required file in rails log file so fail2ban will live
After=mnt-dietpi_userdata-rails_application-log.mount
Requires=mnt-dietpi_userdata-rails_application-log.mount

[Service]
Type=oneshot
ExecStart=/usr/bin/touch /mnt/dietpi_userdata/rails_application/log/production.log
ExecStart=/usr/bin/chown dietpi:dietpi /mnt/dietpi_userdata/rails_application/log/production.log
ExecStart=/usr/bin/chmod 640 /mnt/dietpi_userdata/rails_application/log/production.log
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
" | sudo tee /etc/systemd/system/create-rails-log-file.service
```

Then we can activate and start it:  
 - `sudo systemctl daemon-reload`  
 - `sudo systemctl enable --now create-rails-log-file.service`  



## For the daring: cloud backups

Yes, it's also mandatory to perform local backups... But you may never know
when you'll forget and when you'll need a backup of the previous day.  

In general I'm agains tcloud backups, but given `rclone`'s ability to encrypt
data before sending it I decided to give it a try.  



### Configure rclone

I advise to download the latest rclone release from
https://github.com/rclone/rclone/releases rather than using the old version
in the repository.  

Now, we need to run `rclone config` twice:  
 - the first time, configure your normal remote cloud provider. Check
   https://rclone.org for more info
 - the second time we need to configure a `crypt` remote using the first remote
   we configured. See: https://rclone.org/crypt/  

At this point `rclone` is ready to perform the backups.



### The backup itself 

What's really important here is that we do want to limit the IO on the sd card
to the bare minimum, so we want to abuse `tmpfs` and `zram` to create a folder
entirely in ram, rsync in there all of our important stuff, then rclone it to
our encrypted remote.  

And while we're here, let's also keep 1 week of backups, sorted by day of the
week.  

Since that's easier said than done I've put together a very simple script to
automate it all. However, know that it might fail if there is not enough ram
available.  

The script is located in `scripts/rclone-backup` and it expects you to:  
 - copy `scripts/rclone-backup` to `/opt/rclone-backup`  
 - edit `rclone-backup.zsh`, look for the `Variables` section and set what fits
   your needs. Most notably:  
    - set `RCLONE_BIN=` to your rclone binary  
    - set `RCLONE_REMOTE=` to use the right rclone remote to use  
    - set `SERVICES_TO_STOP=` as the list of services to sop as data gets
      copied  
    - set `RSYNC_PATHS=` as the list of folders to copy over  
    - set `TMPFS_SIZE=` so it won't kill your ram.  

After that you can give the script a try, and if it works you can simply use
the service and timer provided in `scripts/rclone-backup/systemd` folder to
automate it:  
 - `sudo cp scripts/rclone-backup/systemd/* /etc/systemd/system`  
 - `sudo systemctl daemon-reload`  
 - `sudo enable --now rclone-backup.timer`  

