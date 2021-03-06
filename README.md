# PRIVATE OCP 4.3 cluster on AWS

## Table of contents

* [Introduction](#introduction)
* [Full cluster installation](#full-cluster-installation)
* [Deploying a cluster in an existing VPC](#Deploying-a-cluster-in-an-existing-VPC)
* [VPC creation](#vpc-creation)
  * [Terraform installation](#terraform-installation)
    * [Variables](#variables)
    * [Endpoints](#endpoints)
    * [Proxy configuration](#proxy-configuration)
  * [Deploying the infrastructure with terraform](#deploying-the-infrastructure-with-terraform)
* [Bastion setup with Ansible](#bastion-setup-with-ansible)
  * [Proxy configuration](#proxy-configuration)
    * [Running the ansible playbook](#running-the-ansible-playbook)
    * [Template constructions](#template-constructions)
* [OCP cluster deployment](#ocp-cluster-deployment)
* [Cluster decommissioning instructions](#cluster-decommissioning-instructions)
* [Accessing the cluster](#accessing-the-cluster)
  * [Turning the private cluster public](#turning-the-private-cluster-public)

## Introduction

Create a VPC on AWS and deploy an OCP 4.3 cluster in it, this cluster is not directly accessible from the Internet, the connections from the cluster to the Internet can be configured via NAT gateways or via a proxy server running in a bastion host. 

[Reference documentation](https://docs.openshift.com/container-platform/4.3/installing/installing_aws/installing-aws-private.html#installing-aws-private)

## Full cluster installation

The installation of the whole cluster is divided in 3 steps, click the following links in order to go to the specific sections: 

* [Create VPC insfrastructure with terraform](#deploying-the-infrastructure-with-terraform)

* [Set up the bastion host](#running-the-ansible-playbook)

* [Install Openshift](#ocp-cluster-deployment)

## Deploying a cluster in an existing VPC

If the cluster is to be deployed in an existing VPC, possibly sharing it with other clusters, the terraform creation part will be skipped and only the Ansible part will be run.

One thing to keep in mind is that two or more cluster can be installed in the same VPC, but the DNS zones must be different for each one if these are OCP v4 public clusters; they can share the same VPC and DNS zone if one of the clusters is v3 and the other is v4.  A private OCP v4 cluster could be deployed on a different VPC using the same private DNS zone as another OCP v4 cluster, because the private cluster does not create public resources.  


There are some requirements:

* A bastion host must be running in the VPC and accesible from the ansible control host, and the ssh key to connect to it must be available.

* The following ansible variables must be defined either in a file located in the directory **Ansible/group_vars/all/**, the name of the file is not important; or appended as extra variables to the ansible command.  When creating the infrastructure with terraform, most of these variables are defined as output vars, but in this case they need to be provided by other means to the ansible playbook that prepares the cluster installation environment:

  * terraform_created.- Boolean defining if the infrastructure was created by terraform and therefore ansible can read the variables from it.  Default values is true.  Use _false_ when deploying on an existing VPC
  * base_dns_domain.- String defining the base domain of your cloud provider.  The full DNS name for your cluster is a combination of the **base domain** and *cluster_name* parameters that uses the <cluster_name>.<baseDomain> format.  The subdomain will be created but the parent domain must exist, for example for abbyext.example.com, example.com must already exist, and abbyext will be created. The DNS zone <cluster_name>.<baseDomain> is a private zone, records will be added to this zone only, not the public **base domain**.
  * enable_proxy.- Boolean defining if a proxy will be setup as the only means to access the Internet from the cluster.  Default is false, no proxy is created and the cluster will try to access the Internet directly.  If set to true a proxy will be setup on the bastion and the cluster will access the Internet through it.
  * availability_zones.- List of availability zones where the VPC has public and private subnets and where cluster nodes will be located.  This list does not need to include all availability zones, only the ones where nodes will be placed.
  * cluster_name.- String defining a name for the cluster.
  * vpc_cidr.- Network address space of the VPC.
  * region_name.- The AWS region name where the VPC resides.
  * private_subnets.- List of _private_ subnet ids already existing in the VPC where cluster components will be created. These subnets must exist in the availability zones declared with the variable *availability_zones* in the same command line.

An example execution with the variables defined on the command like follows:

```shell
$ ansible-playbook -i inventory privsetup.yaml --vault-id vault-id -e terraform_created=false -e base_dns_domain=example.com -e enable_proxy=false -e '{"availability_zones": ["eu-west-1a","eu-west-1b"]}' -e cluster_name=rhpnt -e vpc_cidr="172.20.0.0/16" -e region_name="eu-west-1" -e '{"private_subnets":["subnet-0ea3ec602f2e0baee", "subnet-0b032d4c5b631a6ea"]}'
```
When the variables are defined follow the instruction in the following sections:

* [Set up the bastion host](#running-the-ansible-playbook)

* [Install Openshift](#ocp-cluster-deployment)


## VPC creation

Create a VPC in AWS using **terraform** to deploy a private OCP 4.3 cluster in it.

In addition to the VPC network components, a bastion host in a public subnet inside the private VPC is required to run the intallation program from it.  This bastion host can also take the role of proxy server for the cluster nodes in the private subnets.

### Terraform installation

The installation of terraform is as simple as downloading a zip compiled binary package for your operating system and architecture from:

`https://www.terraform.io/downloads.html`

Then unzip the file:

```shell
 # unzip terraform_0.11.8_linux_amd64.zip 
Archive:  terraform_0.11.8_linux_amd64.zip
  inflating: terraform
```

Place the binary somewhere in your path:

```shell
 # cp terraform /usr/local/bin
```

Check that it is working:

```shell
 # terraform --version
```

### Variables

All input variables and locals are defined in a separate file _Teraform/input-vars.tf_.  This file can be used as reference to know what components of the VPC or bastion can be specified at the time of creation.

### Endpoints

A best practice when deploying the VPC is creating endpoints for all the AWS services that are used by the OCP cluster, this will improve security and speed since the communications between the cluster and these services never live the AWS internal network.  The use of endpoints is a must in case the cluster only access to the Internet is via a proxy server.

The AWS services used by OCP and available as endpoints are: 

* s3.- Of type Gateway, is associated with all route tables defined in subnets where the it will be used.
* ec2 and elastic load balancing.- Of type Interface, requires private dns enabled, is associated with the subnets where it will be used, with the limitation of only one subnet per availability zone.  Also security groups must be assigned to them to define what ports are allowed from where.
* elastic load balancing.- Of type Interface, requires private dns enabled, is associated with the subnets where it will be used, with the limitation of only one subnet per availability zone.  Also security groups must be assigned to them to define what ports are allowed from where.


### Proxy configuration

If the access from the cluster nodes to the wider Internet will be routed through a proxy server the variable **enable_proxy** must be set to true, by default is false.  This variable is used in several conditional expressions to decide on the configuration of some components:

* The security groups assigned to the bastion host.- If the proxy is enabled, a security group for ingress port 3128 is created and later added to the bastion, this port is where squid proxy provides its service. 

```
resource "aws_security_group" "sg-squid" {
    count = var.enable_proxy ? 1 : 0
...
bastion_security_groups = var.enable_proxy ? concat([aws_security_group.sg-ssh-in.id, aws_security_group.sg-all-out.id], aws_security_group.sg-squid[*].id) : [aws_security_group.sg-ssh-in.id, aws_security_group.sg-all-out.id]
...
resource "aws_instance" "tale_bastion" {
  ami = var.rhel7-ami[var.region_name]
  instance_type = "m4.large"
  subnet_id = aws_subnet.subnet_pub.0.id
  vpc_security_group_ids = local.bastion_security_groups
```

* Public subnets.- If the proxy is enabled only one public subnet is created to place the bastion host, if not enabled as many public as private subnets are created:

```
public_subnet_count = var.enable_proxy ? 1 : local.private_subnet_count
```
* NAT gateways.- If the proxy is enable NAT gateways, its elastic IPs and the route to use them will not be created, since all the Internet bound connections will go through the proxy.
```
resource "aws_eip" "nateip" {
  count = var.enable_proxy ? 0 : local.public_subnet_count
...
resource "aws_nat_gateway" "natgw" {
    count = var.enable_proxy ? 0 : local.public_subnet_count
...
resource "aws_route" "internet_access" {
  count = var.enable_proxy ? 0 : local.private_subnet_count
  route_table_id = aws_route_table.rtable_priv[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_nat_gateway.natgw[count.index].id
}
```

### Deploying the infrastructure with terraform

Terraform is used to create the infrastructure components of the VPC, some of these components can be adjusted via the use of variables defined in the file _Terrafomr/input-vars.tf_, like the number of subnets, if a proxy will be used to manage connections from the cluster to the Internet, the name of the cluster, the name of the DNS subdomain to use, etc.  

The DNS base domain for the cluster, created by terraform, is built from two variables: the domain defined in dns_domain_ID and the subdomain defined in domain_name.  The cluster domain created by the IPI installer will be created adding the cluster name to the base domain.  For example for a dns_domain_ID referencing "example.com", a domain_name=avery, and cluster_name=tiesto, the base domain is avery.example.com and the cluster domain is tiesto.avery.example.com: 

```shell
$ cd Terraform
$ terraform apply -var="subnet_count=2" -var="domain_name=kali" -var="cluster_name=olivkaj" -var="enable_proxy=true"
```

Save the value of the variables used in this step becasuse the same values will be required in case the infrastructure wants to be destroyed with the **terrafor destroy** command.  In the example the use of !! assumes that no other command has been executed after _terraform apply_:

```
$ echo "!!" > terraform_apply.txt
```

## Bastion setup with Ansible

To successfully deploy the cluster some elements are required besides the AWS infrastructure created above:

* Permanent credentials for an AWS account

* An ssh key pair (Optional).- the public part of the key will be installed on every node in the cluster so it is possible to connect to them via ssh.

* A DNS base domain.- This can be a public or private domain.  A private subdomain will be created under the base domain and all DNS recrods created during installation will be created in the private subdomain 

* Pull secret.- The pull secret can be obtained [here](https://cloud.redhat.com/openshift/install)

* Installer program.- This can be downloaded from the same [site](https://cloud.redhat.com/openshift/install) as the pull secret

The setup process can be automated using the ansible playbook **privsetup.yaml**, this playbook prepares de bastion host created with terraform, registering it with Red Hat; copying the OCP installer and _oc_ command to it, and creating the install-config.yaml file generated from a template using output variables from terraform.

### Proxy configuration

The same variable used by terraform to enable the proxy is used by ansible, read from the output variables stored in the file *Ansible/group_vars/all/terraform_outputs.var*.  If this boolean variable is set to true, a block of tasks is executed to install, setup and enable the proxy squid service.  The setup of squid just consists of adding an ACL line with the network range of the VPC, so any host with an IP in the VPC can access the Internet through the proxy, no authentication is required:
```
 - name: Add localnet to squid config file
   lineinfile:
     path: /etc/squid/squid.conf
     insertafter: '^acl localnet'
     line: 'acl localnet src {{ vpc_cidr }} #Included by Ansible for VPC access'
```

The install-config.j2 template also contains a conditional block to add the proxy configuration if the *enable_proxy* variable is enabled
```
{% if enable_proxy|bool %}
proxy:
  httpProxy: http://{{bastion_private_ip}}:3128
  httpsProxy: http://{{bastion_private_ip}}:3128
  noProxy: {{ vpc_cidr }}
{% endif %}
```

#### Running the ansible playbook

Review the file **group_vars/all/cluster-vars** and modify the value of the variables to the requirements for the cluster:

* terraform_created.- Boolean signaling that the infrastructure was created by terraform and the output variables it generates can be used by ansible. By default is true, when false, ansible will not try to read terraform output vars.
* compute_nodes.- number of compute nodes to create, by default 3
* compute_instance_type.- The type of AWS instance that will be used to create the compute nodes, by default m4.large 
* master_nodes.- number of master nodes to create, by default 3
* master_instance_type: The type of AWS instance that will be used to create the master nodes, by default m4.large m4.xlarge 

Create a file in group_vars/all/<filename> (any filename will work) with the credentials of a Red Hat portal user with permission to register a host (this may not be absolutely neccessary since the playbook does not install any packages in the bastion host). An example of the contents of the file:

```
subscription_username: algol80
subscription_password: YvCohpUKjEHx
```
It is a good idea to encrypt this file with ansible-vault

Create the inventory file with the _bastion_ group and the name of the bastion host:

```
[bastion]
bastion.olivka.example.com
```
Download the pull secret from [here](https://cloud.redhat.com/openshift/install) and save in a file called pull-secret in the Ansible directory.

Download the oc client and installer from the same [site](https://cloud.redhat.com/openshift/install)

Uncompress the client in the Ansible directory

Uncompress the installer in Ansible/installer/ 

Add the ssh key used by terraform to the ssh agent:

```shell
$ ssh-add ../Terraform/ocp-ssh
```

Run the playbook:

```shell
$ ansible-playbook -vvv -i inventory privsetup.yaml --vault-id vault-id
```

#### Template constructions 

The template used to create the install-config.yaml configuration file uses some advance contructions:

* Regular expresion filter.- The base_dns_domain variable from terraform includes a dot (.) at the end, that has to be removed, otherwise the cluster installation fails, for that a regular expresion filter is used:

```
baseDomain: {{ base_dns_domain | regex_replace('(.*)\.$' '\\1') }}
```

* for loops.- The variable containing the values is *availability_zones*, it comes from terraform and ansible understands it as a list in its original form, except for the substitution of the equal sign for the colom:

```
availability_zones : [
  "eu-west-1a",
  "eu-west-1b",
]
```

```
{% for item in availability_zones %}
        - {{ item }}
{% endfor %}
```
* Content from another file.- The pull secret and ssh key is loaded from another file:

```
pullSecret: '{{ lookup('file', './pull-secret') }}'
```


## OCP cluster deployment

When the playbook finishes, ssh into the bastion host to run the cluster installation.  The installation must be executed from a host in the same VPC that was created by terraform, otherwise it will not be able to resolve the internal DNS names of the components or even access to the API entry point.

Run the installer from the privOCP4 directory, it will prompt for the AWS credentials that will be used to create all resources:

```shell
$ cd privOCP4
$ ./openshift-install create cluster --dir ocp4 --log-level=info
? AWS Access Key ID [? for help] XXXXX
? AWS Secret Access Key [? for help] ****************************************
```

## Cluster decommissioning instructions

Deleting the cluster is a two step process:

* Delete the components created by the openshift-install binary, run this command from the same bastion host and directory from where the installation was run:

```shell
$ ./openshift-install destroy cluster --dir ocp4 --log-level=info
```

* Delete the components created by terraform,  use the `terraform destroy` command.  This command should include the same variable definitions that were used during cluster creation, not all variables are strictly requiered though.  This command is run from the same host and directory from which the `terraform apply` command was run:

```shell
$ cd Terraform
$ terraform destroy -var="subnet_count=2" -var="domain_name=kali" -var="cluster_name=olivkaj" -var="enable_proxy=true"
```

## Accessing the cluster

Once the cluster is up and running, it is only accessible from inside the VPC, for example from the bastion host using the *oc* client copied into the privOCP4 directory, or a web browser for accessing the applications.

It is also possible to access the cluster applications from outside the VPC by creating a temporary ssh tunnel through the bastion host to the internal applications load balancer.  Create a tunnel from a host outside the VPC, through the bastion, to the internal apps load balancer with the following commands.  Since the starting point of the tunnel uses priviledged ports, the commands must be run as root.  The ssh private key added to the session must be the same one injected into the nodes by terraform.  Any hostname in the apps subdomain is valid:

```
 # ssh-agent bash
 # ssh-add Terraform/ocp-ssh
 # ssh -fN -L 80:console-openshift-console.apps.lentisco.tangai.example.com:80 ec2-user@bastion.tangai.rhcee.support
 # ssh -fN -L 443:console-openshift-console.apps.lentisco.tangai.example.com:443 ec2-user@bastion.tangai.rhcee.support
```
Next add entries to /etc/hosts with the names that will be used to access the URL, for example to access the web console: 
```
127.0.0.1 console-openshift-console.apps.lentisco.tangai.rhcee.support
127.0.0.1 oauth-openshift.apps.lentisco.tangai.rhcee.support
```
Now it is possible to access the cluster's web console using the URL `https://console-openshift-console.apps.lentisco.tangai.rhcee.support`

### Turning the private cluster public

It is possible to modify the configuration of the OCP cluster to be able to access the applications from the Internet in a permanent way, without the need of tricks like ssh tunnels.

The procedure consists on replacing the internal applications load balancer created by the control plane during installation by a public applications load balancer, and also adding a DNS entry **.apps.[cluster name]** to a public DNS zone hosting the cluster base domain.

* **Create public subnets**.- If the cluster does not already have a public subnet in every availability zone where a private subnet already exist, these must be created, each public subnet must get a CIDR network space from the VPC CIDR space, that is available and not used by another subnet.  Each public subnet must have an association with a route table that has a default route to the VPC's Internet Gateway.

* **Put the public subnets under OCP control**.- To make the cluster aware of the public subnets, a particular tag must be added to the subnets.  The tag is created for most of the AWS resources during cluster installation and has the format **kubernetes.io/cluster/[clustername]-[random string]=shared**.  The particular value for a cluster can be obtainend from the existing private subnets.  This same tag must be added to the public subnets.

* **Create default ingress controller manifest**.- The default ingress controller provides access to the applications deployed in the cluster and accessed under the DNS domain _*.apps_.  One of the components managed by the ingress controller is an applications load balancer, in the case of a private cluster this load balancer is created in the private subnets and is not accesible from the Internet.  

  Extract the default ingress controller configuration:

```shell
$ oc get ingresscontroller default -n openshift-ingress-operator -o yaml > default-ingress-controller.yaml
```

  Edit the file and remove the whole status section, and in the metadate section just leave the name and namespace entries.  The result should look similar to this:

```yaml
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: default
  namespace: openshift-ingress-operator
spec:
  endpointPublishingStrategy:
    loadBalancer:
      scope: Internal
    type: LoadBalancerService
```
 
  Modify the __scope__ entry in the yaml definition and replace __Internal__ by __External__.  The scope section tells the ingress operator where to create the load balancer, whether in the private or public subnets inside the VPC.

* **Replace the ingress controller**.- Run the following command as an administrator, the execution takes a couple minutes while the control plane deletes the internal load balancer and creates a new external one.

```shell
 $ oc replace --force --wait -f default-ingress-controller.yaml
 ingresscontroller.operator.openshift.io "default" deleted
 ingresscontroller.operator.openshift.io/default replaced
```

  The events in the openshift-ingress and openshift-ingress-operator namespaces, and the logs in the ingress-operator deployment should show the actions being taken to replace the ingress controller.   

```shell
 $ oc get events -w -n openshift-ingress-operator
 $ oc get events -w -n openshift-ingress
 $ oc logs -f deployment/ingress-operator -c ingress-operator -n openshift-ingress-operator
```
 Check the status section of the new ingress controller and verify that all conditions are as expected:
```shell
 $ oc describe ingresscontroller default -n openshift-ingress-operator
```
  A new applications load balancer must exist now, and the old one has been deleted, check it with AWS cli or web console.

* **DNS configuration**.- Add a public DNS entry with the format __*.apps.[cluster name]__ and value aliased to the DNS name of the just created public load balancer to the _base domain_ DNS public zone.  If the _base domain_ zone is not public, a new public zone with the same name must be created, otherwise the applications DNS names will not be resolvable from the Internet.  Note that the __*.apps.[cluster name]__ entry is created in the _base domain_ public zone, not in the __[cluster name].[base domain]__ private zone.  Now the cluster applications can be accessed from the Internet, including the cluster web console.

