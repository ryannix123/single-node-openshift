
# Getting started with Single Node OpenShift

Single Node OpenShift is a great way to both try out OpenShift in a lab environment and deploy Kubernetes for edge cases.

**_Minimum requirements: One host is required with at least 8 CPU cores, 32.00 GiB of RAM, and 120 GB of filesystem storage._**

**_Additionally, a fixed IP for the system is not available yet through the Assisted Installer, so you'll need to use DHCP, preferably with a DHCP reservation._**

1. Log into [cloud.redhat.com][1] with your Red Hat account.

2. Click OpenShift from the left-side panel, then click "Create Cluster".

3. Click Datacenter from the top navigation pane.

4. Under Assisted Installer, click "Create cluster."

5. Fill out your cluster's details. i.e., cluster name, base domain. Check the option for "Install single node OpenShift.", and click the agreement "*I understand, accept, and agree to the limitations associated with using Single Node OpenShift*." Click Next

6. Click Generate Discovery ISO and download the ISO to your system. Keep this browser window open, as you will need it later in the installation process. Add your ssh public when prompted. e.g., `cat \~/.ssh/id\_ed25519.pub | pbcopy`

7. Upload the ISO to your host system of choice that meets the requirements listed above, and follow the installation instructions in the Assisted Installer's WebUI on [cloud.redhat.com][2]. The WebUI will force you to change the hostname to something other than localhost. Select the appropriate network range when prompted by the installer.

8. When the installation is finished, download the Kubeconfig file and make a note of the kubeadmin password listed in the portal.

9. Download OpenShift command line client by browsing to [https://mirror.openshift.com/pub/openshift-v4/x86\_64/clients/ocp/stable/][3] and download the client appropriate for your system. Make sure to download the client version that corresponds to the version of OpenShift that you are running. e.g. If you're using OCP 4.8.9, make sure to download the matching client version.
You may also want to run these commands from a macOS or Linux based system:
```shell
curl -o oc.tar.gz https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz
sudo tar -C /usr/local/bin -xzvf oc.tar.gz
sudo install -t /usr/local/bin {kubectl,oc}
```

10. After downloading and installing the OpenShift command line tool and Kubeconfig from [cloud.redhat.com][4], set the KUBECONFIG environment variable to the location of your Kubeconfig, then test the connection:

```shell
export KUBECONFIG=~/Downloads/kubeconfig`
```
Run the following command to confirm you can list cluster resources:

```shell
oc get nodes
```
  
# Add a non-admin account to your OpenShift system

It's best to only use the `kubeadmin` user when you need elevated privileges for the cluster. e.g., adding an operator. The easiest way to set up a local non-admin user is to use htpasswd. Create the users.htpasswd using the following command for a testuser:

```shell
htpasswd -c -B users.htpasswd testuser
```

Log into the web console with the kubeadmin account and password, then click the blue warning at the top asking to add an OAuth provider. Use htpassword, and upload your users.htpasswd file. Wait roughly 20 to 60 seconds, log out of the OpenShift web console, and you should see htpasswd as an additional authentication provider. Login to make sure the new account works.

# Add ephemeral storage for the container registry

OpenShift uses CoreOS for the underlying OS. CoreOS is based on RHEL 8, and is an immutable operating system. Since this is a test system, we will set the registry to an empty directory. All images will be lost in the event of a registry pod restart.

Patch the registry operator to management state and storage by running the following commands as Kubeadmin:
```shell
oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed"}}'

oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"storage":{"emptyDir":{}}}}'
```

# Add three DNS entries to get started

You'll need add some DNS entries. api.ocp.mydomain.com, apit-init.ocp.mydomain.com and \*.apps.ocp.mydomain.com should point to your external IP address. e.g., I use Cloudflare to host my domain's DNS. Keep your domain management tab open as you'll need to add a TXT record later when obtaining a Let's Encrypt certificate that is based on DNS verification.

# Open ports on your router

Make sure ports 80, 443, 8080, and 6443 are open to your Single Node OpenShift's IP.

# Set a DHCP reservation on your router

SNO uses for DHCP for now, so in order to ensure the IP address of your instance doesn't change, look up the instructions for setting a DHCP reservation on your router. e.g., I use a [Netgear home router][5].

# Add a Let's Encrypt wildcard certificate for the console and router

**You should run these instructions from a RHEL based system. [You can use up to 16 free subscriptions of RHEL.][6]** I run RHEL from a Virtualbox VM.

1. Download the OpenShift command line client to your RHEL system by browsing to [https://mirror.openshift.com/pub/openshift-v4/x86\_64/clients/ocp/stable/][7] and download the client appropriate for your system.
You may also want to run these commands from your RHEL VM:
```shell
curl -o oc.tar.gz https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz
sudo tar -C /usr/local/bin -xzvf oc.tar.gz
sudo install -t /usr/local/bin {kubectl,oc}
```

2. Change to the root user, `sudo su`, it's necessary to switch to root because the Let's Encrypt certs are stored in a secure area of your RHEL system.

3. then log into the OpenShift console as Kubeadmin, and from top right-hand menu, click the dropdown to "copy the login command".

4. Paste the login command to the RHEL based system where the `oc` client is installed so that you are logged into SNO as a cluster administrator.

After adding the appropriate DNS entires, run the following commands:

```shell
sudo yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
sudo yum update
sudo yum install epel-release certbot
certbot -d '*.apps.ocp.mydomain.com' --manual --preferred-challenges dns certonly
```

Create the TXT create that Certbot needs to validate domain ownership, then press enter when the records are in place. You should receive a message from Certbot that the certificates were saved to your RHEL system. Note the date of expiration. ***Let's Encrypt certs will need replacing in \< than 90 days***.

```shell
Successfully received certificate.
Certificate is saved at: /etc/letsencrypt/live/apps.ocp.mydomain.com/fullchain.pem
Key is saved at: /etc/letsencrypt/live/apps.ocp.mydomain.com/privkey.pem
This certificate expires on 2021-12-06.
These files will be updated when the certificate renews.
```

Now we have the certificates necessary to replace the default certs for OpenShift's [ingress][8].

Switch to to the root user and login to the cluster as kubadmin. It's necessary to run these commands as root since the Let's Encrypt certs are in a secure area of your RHEL system. `sudo su` then run the command from earlier to log into OpenShift as the root user. e.g., `oc login --token=sha256~K2aKXufTkVudbcfWIPMlIr5YUMQkpw-MAOG51dGVQw --server=https://api.sno.openshifthelp.com:6443`

Finally, let's run the following commands to upload our certs and properly secure our instance of OpenShift!

```shell
oc create configmap letsencrypt-ca-20211206 \
     --from-file=ca-bundle.crt=/etc/letsencrypt/live/apps.ocp.mydomain.com/fullchain.pem \
     -n openshift-config

oc patch proxy/cluster \
     --type=merge \
     --patch='{"spec":{"trustedCA":{"name":"letsencrypt-ca-20211206"}}}'

oc create secret tls letsencrypt-ca-secret-20211206 \
     --cert=/etc/letsencrypt/live/apps.ocp.mydomain.com/fullchain.pem \
     --key=/etc/letsencrypt/live/apps.ocp.mydomain.com/privkey.pem \
     -n openshift-ingress

oc patch ingresscontroller.operator default \
     --type=merge -p \
     '{"spec":{"defaultCertificate": {"name": "letsencrypt-ca-secret-20211206"}}}' \
     -n openshift-ingress-operator
```

The instance of Single Node OpenShift is not set with a Let's Encrypt certificate. Any applications you deploy, preferably as a non-admin, should use the Let's Encrypt certificate by default. 

# Shutting down your instance of SNO cleanly

First, determine when the cluster certificates expire, and plan to shut it down on or before the expiration date. 

From the command line on either your local system or your RHEL system, run the following command as Kubeadmin:

```shell
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do oc debug node/${node} -- chroot /host shutdown -h 1; done
```

# Notes

### Shutting down your cluster for a while
If you are shutting the cluster down for an extended period, determine the date on which certificates expire.
```shell
oc -n openshift-kube-apiserver-operator get secret kube-apiserver-to-kubelet-signer -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}'
```

Example result:

`2022-10-18T20:58:57ZC02F33X2MD6R:single-node-openshift rnix$` 

The date of expiry is listed at the front, e.g., The certs will expire on 10-18-2022.

### Making it easier to reach your SNO and RHEL instance from your local network

You may need to modify the `/etc/hosts` file on your system so that your system is aware of the SNO instance. e.g., `192.168.0.19 sno`

After modifying /etc/hosts, you should try ssh'ing into your system. e.g., `ssh coreos@sno`

[1]:	https://cloud.redhat.com
[2]:	https://cloud.redhat.com
[3]:	https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/
[4]:	https://cloud.redhat.com
[5]:	https://kb.netgear.com/25722/How-do-I-reserve-an-IP-address-on-my-NETGEAR-router
[6]:	https://developers.redhat.com/articles/faqs-no-cost-red-hat-enterprise-linux#general
[7]:	https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/
[8]:	https://docs.openshift.com/container-platform/4.8/security/certificates/replacing-default-ingress-certificate.html