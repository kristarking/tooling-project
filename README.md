# Tooling Web App — Production Deployment on Azure Kubernetes Service

**Author:** Christopher Ojedayo  
**Domain:** [https://heros.com.ng](https://heros.com.ng)  
**Stack:** Azure · AKS · Terraform · GitHub Actions · Docker · Helm · cert-manager · Cloudflare · Prometheus · Grafana

---

## What This Project Is

This is a production-grade deployment of a web application on Azure Kubernetes Service. The entire infrastructure is provisioned with Terraform, the application is containerized and stored in Azure Container Registry, and every deployment happens automatically through a GitHub Actions CI/CD pipeline. The app runs behind an NGINX Ingress Controller with TLS certificates issued by Let's Encrypt via cert-manager, and traffic reaches it through a Cloudflare Tunnel that removes the need for your Azure IP to be publicly reachable at all.

This was not a clean, one-shot deployment. It went through real troubleshooting across multiple sessions — NSG rule bugs, ACME challenge failures, ISP-level IP blocking, and a full region migration from East US to West Europe. Every one of those issues is documented here so you understand not just how to deploy it, but what can go wrong and why.

> **📸 Screenshot:** *Final browser view — heros.com.ng loading with HTTPS padlock*

---

## Architecture Overview

```
User Browser
     │
     ▼
Cloudflare Edge (proxied, orange cloud)
     │
     ▼
Cloudflare Tunnel (outbound from inside AKS — no direct Azure IP exposure)
     │
     ▼
cloudflared pod (namespace: cloudflare-tunnel)
     │
     ▼
NGINX Ingress Controller (namespace: ingress-nginx)
     │
     ├──▶ tooling-web pods (namespace: tooling) × 2 replicas
     │         │
     │         └──▶ MySQL StatefulSet (tooling-db-0)
     │
     └──▶ Grafana (namespace: monitoring) — LoadBalancer IP
```

**TLS flow:** cert-manager issues certificates from Let's Encrypt using DNS-01 challenge via Cloudflare's API. The tunnel handles all inbound traffic so the Azure LoadBalancer IP never has to be directly reachable from the internet.

---

## Infrastructure Summary

| Component | Value |
|---|---|
| Cloud Provider | Microsoft Azure |
| Region | West Europe |
| AKS Cluster | tooling-aks |
| Resource Group | tooling-rg |
| ACR Registry | toolingacr.azurecr.io |
| Ingress Controller | NGINX (ingress-nginx Helm chart) |
| TLS Provider | cert-manager + Let's Encrypt (letsencrypt-prod) |
| Challenge Type | DNS-01 via Cloudflare API |
| App Namespace | tooling |
| Database | MySQL 5.7 (StatefulSet: tooling-db-0) |
| Monitoring | Prometheus + Grafana (kube-prometheus-stack) |
| Domain | heros.com.ng |
| DNS Provider | Cloudflare |
| Ingress IP | 4.175.121.155 (West Europe — bypassed via tunnel) |
| CI/CD | GitHub Actions |
| IaC | Terraform |
| Terraform State | Azure Blob Storage (toolingtfstateprod / tfstate container) |

---

## What You Need Before You Start

Before you try to deploy this, make sure the following are sorted on your end.

**Accounts**

You need an active Azure account with a valid subscription. This project creates resources that cost money — AKS, ACR, Load Balancer, storage. Tear things down when you are done if you are not actively using them.

You need a GitHub account with this repo forked or cloned into your own space. The CI/CD pipeline runs on GitHub Actions and requires secrets to be added to your repo settings before it will work.

You need a Cloudflare account. The free plan is enough for everything this project does. Your domain must be using Cloudflare's nameservers — this is non-negotiable because both the TLS certificate issuance (DNS-01) and the Cloudflare Tunnel depend on it.

**Local Tools**

You need the Azure CLI (`az`) installed for generating the service principal credentials. You need `kubectl` for connecting to and inspecting your cluster. Having `terraform` and `helm` installed locally is useful if you want to debug or modify things, but the pipeline handles the actual execution.

**Domain**

You need a domain name that you own and can update the nameservers for. This project uses `heros.com.ng`. Everywhere you see that in this README, swap it out for yours.

---

## Cloudflare Setup — Step by Step

Cloudflare carries two responsibilities in this project. The first is handling DNS and TLS certificate issuance through its API, so cert-manager can complete Let's Encrypt DNS-01 challenges without port 80 ever being involved. The second is running a tunnel so traffic can reach your app inside AKS without your Azure IP ever being directly hit from the outside world.

### Step 1 — Create a Cloudflare Account and Point Your Domain to It

Go to [cloudflare.com](https://cloudflare.com) and create a free account. Once you are in, click **Add a Site** and enter your domain name. Pick the Free plan. Cloudflare will scan your existing DNS records and then give you two nameserver addresses that look something like `crystal.ns.cloudflare.com` and `milan.ns.cloudflare.com`.

Log into wherever you registered your domain and replace the current nameservers with the two Cloudflare gave you. This is the only thing you will ever do on your domain registrar from this point forward. All DNS management moves to Cloudflare from here. It can take up to 24 hours for the nameserver change to fully propagate, though it is usually done in a couple of hours.

> **📸 Screenshot:** *Cloudflare dashboard showing domain active with nameservers*

### Step 2 — Add Your DNS A Records in Cloudflare

Once Cloudflare confirms your domain is active, go to the **DNS** section. This is where you will add the A records pointing to your NGINX Ingress external IP.

You will not know the IP yet at this stage — it only exists after the pipeline runs and AKS provisions the LoadBalancer. So come back to this step once the pipeline prints the IP in its logs. When you have it, add two A records:

One record with the name `@` pointing to your ingress IP. This covers the root domain (`heros.com.ng`).

One record with the name `www` pointing to the same ingress IP. This covers `www.heros.com.ng`.

Set both records to **grey cloud (DNS only)** while the pipeline is running. The pipeline has a DNS wait loop that checks whether your domain is resolving to the ingress IP, and that check fails if Cloudflare is proxying because it returns Cloudflare's own IPs instead of yours. After the certificate is issued and the tunnel is up, you will switch these to orange cloud.

> **📸 Screenshot:** *Cloudflare DNS section showing A records with grey cloud*

### Step 3 — Create a Cloudflare API Token

cert-manager needs this token to create and delete DNS TXT records on your behalf during the Let's Encrypt DNS-01 challenge. Without it, the challenge cannot complete and your certificate will never issue.

In the Cloudflare dashboard, click your profile icon in the top right corner and go to **My Profile**. Click **API Tokens**, then **Create Token**. Click **Use template** next to **Edit zone DNS**. Under Zone Resources, select your specific domain from the dropdown so the token is scoped only to that zone. Click **Continue to summary**, then **Create Token**.

Copy the token the moment it appears. Cloudflare only shows it once. If you lose it you will have to create a new one.

This token goes into your GitHub Actions secrets as `CLOUDFLARE_API_TOKEN`.

> **📸 Screenshot:** *Cloudflare API token creation with Edit zone DNS template selected*

### Step 4 — Create a Cloudflare Tunnel

This is what made the final deployment work. The Azure IP was unreachable from Nigerian ISPs regardless of what region the cluster was in. The tunnel fixes this by flipping the connection direction — instead of Cloudflare trying to reach your Azure IP, the cloudflared pod inside your cluster reaches out to Cloudflare. Traffic then flows: user → Cloudflare edge → through that outbound tunnel connection → into your cluster → to your app. Your Azure IP never has to accept any inbound connection from the outside.

In the Cloudflare dashboard, go to **Zero Trust** in the left sidebar. If it asks you to pick a team name, type anything — it has no effect on billing. Then go to **Networks** → **Tunnels** and click **Create a Tunnel**. Choose **Cloudflared** as the connector type and give the tunnel a name like `tooling-aks`.

On the next screen, select **Docker** as the environment. You will see a `docker run` command with a long token embedded in it. That token is the only thing you need from this screen — it is a long string starting with `eyJ...`. Copy it and store it somewhere safe.

After the tunnel is created you will come back to configure the public hostname routes. That step happens after the cloudflared pod is running in your cluster, which is covered later in the deployment steps.

> **📸 Screenshot:** *Cloudflare Zero Trust tunnel page showing the new tunnel created*

---

## GitHub Secrets Setup

Go to your GitHub repo, click **Settings** → **Secrets and variables** → **Actions** → **New repository secret**. You need to add all five of these before the pipeline will work.

### AZURE_CREDENTIALS

This is a JSON block that the pipeline uses to authenticate with Azure. You generate it by creating a service principal. Run the following in your terminal after logging into Azure CLI:

```bash
az login

az ad sp create-for-rbac \
  --name tooling-auth-v2 \
  --role Owner \
  --scopes /subscriptions/<your-subscription-id> \
  --sdk-auth
```

The output will be a JSON object with fields like `clientId`, `clientSecret`, `tenantId`, and `subscriptionId`. Copy the entire thing, curly braces and all, and paste it as the value of this secret.

> **📸 Screenshot:** *GitHub repo settings showing all five secrets added*

### CLOUDFLARE_API_TOKEN

Paste the token you created in Cloudflare in Step 3 above.

### GRAFANA_PASSWORD

Any password you choose. This is what you will use to log into the Grafana monitoring dashboard.

### MYSQL_PASSWORD

The password for the MySQL application user. The project uses `admin` as a placeholder — use something stronger for your own deployment.

### MYSQL_ROOT_PASSWORD

The MySQL root password. Same story — `admin` is the placeholder here, change it for anything beyond a test.

---

## Terraform Remote State Setup

Terraform needs somewhere to store its state file between pipeline runs. That storage lives in Azure Blob Storage and has to be created manually once before you push anything. Run these commands:

```bash
az group create --name tooling-tfstate-rg --location westeurope

az storage account create \
  --name toolingtfstateprod \
  --resource-group tooling-tfstate-rg \
  --location westeurope \
  --sku Standard_LRS

az storage container create \
  --name tfstate \
  --account-name toolingtfstateprod
```

The location here is `westeurope` to match the AKS cluster region. If you change the region in `terraform/main.tf`, update this to match.

---

## How the CI/CD Pipeline Works

Two GitHub Actions workflows trigger on every push to `main`. The Terraform workflow provisions or updates the infrastructure. The CI/CD workflow builds the Docker image, scans it, and deploys the app.

The deployment job inside the CI/CD workflow runs in a very specific order and that order matters:

1. All namespaces are created first (`tooling`, `ingress-nginx`, `cert-manager`, `monitoring`, `cloudflare-tunnel`)
2. NGINX Ingress Controller is installed and the external IP gets printed in the pipeline logs
3. The pipeline waits for DNS propagation, checking every 30 seconds until both `heros.com.ng` and `www.heros.com.ng` resolve to the ingress IP
4. cert-manager installs only after DNS is confirmed
5. All three cert-manager pods (`cert-manager`, `cert-manager-webhook`, `cert-manager-cainjector`) have to be fully ready before anything else continues
6. The Cloudflare API token secret is created in the `cert-manager` namespace
7. The ClusterIssuer is applied using a polling loop rather than `kubectl wait`, which is unreliable for this resource type
8. Database secrets are created
9. The app is deployed via Helm
10. The database schema is imported, with error handling so re-deploys do not fail when tables already exist
11. The Prometheus and Grafana monitoring stack is installed last

Getting this order wrong is the fastest way to end up with a certificate that will never issue. cert-manager cannot do its job without a working ingress and without DNS already pointing at it.

> **📸 Screenshot:** *GitHub Actions showing both workflows passed*

---

## Deploying the App

### Step 1 — Clone and Push

```bash
git clone https://github.com/kristarking/tooling-project.git
cd tooling-project
git add .
git commit -m "initial deployment"
git push origin main
```

Both workflows will kick off automatically.

### Step 2 — Grab the Ingress IP and Update Cloudflare DNS

Watch the pipeline in the GitHub Actions tab. When it reaches the ingress-nginx install step, it will print the external IP that Azure assigned. Copy that IP, go to your Cloudflare DNS settings, and update both A records (`@` and `www`) to point to it. Leave them on grey cloud for now.

The pipeline will hold at the DNS propagation step until `nslookup heros.com.ng 8.8.8.8` returns that IP. Once DNS confirms, the pipeline moves forward on its own.

> **📸 Screenshot:** *Pipeline logs with the ingress external IP printed*

### Step 3 — Connect kubectl to Your Cluster

```bash
az aks get-credentials --resource-group tooling-rg --name tooling-aks
```

### Step 4 — Deploy the Cloudflare Tunnel

The pipeline does not handle the tunnel deployment because the tunnel token is specific to each person's Cloudflare account. You do this once manually after the pipeline finishes.

Store the tunnel token as a Kubernetes secret:

```bash
kubectl create namespace cloudflare-tunnel --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic cloudflare-tunnel-token \
  --from-literal=token='<your-tunnel-token-from-cloudflare>' \
  -n cloudflare-tunnel
```

Create a file called `cloudflared.yaml` (on Windows, use Notepad rather than Git Bash to avoid heredoc formatting issues):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflare-tunnel
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
      - name: cloudflared
        image: cloudflare/cloudflared:latest
        args: ["tunnel", "--no-autoupdate", "run", "--token", "$(TUNNEL_TOKEN)"]
        env:
        - name: TUNNEL_TOKEN
          valueFrom:
            secretKeyRef:
              name: cloudflare-tunnel-token
              key: token
```

Apply it:

```bash
kubectl apply -f cloudflared.yaml
```

### Step 5 — Configure Public Hostname Routes in Cloudflare

Go back to Cloudflare → Zero Trust → Networks → Tunnels → click your tunnel → **Public Hostnames** → **Add a public hostname**.

Add two routes:

The first one has no subdomain, domain set to `heros.com.ng`, and the service set to `http://tooling-web-service.tooling.svc.cluster.local:80`.

The second has subdomain `www`, domain `heros.com.ng`, and the same service URL.

That URL format is Kubernetes internal DNS. Because cloudflared runs as a pod inside the cluster, it can reach any Kubernetes service using this pattern: `<service-name>.<namespace>.svc.cluster.local:<port>`. It never leaves the cluster to do it.

> **📸 Screenshot:** *Cloudflare tunnel public hostname routes configured*

### Step 6 — Switch Cloudflare to Orange Cloud

In Cloudflare DNS, click the grey cloud icon next to both A records to flip them to orange (proxied). Then go to **SSL/TLS** and set the encryption mode to **Full**.

> **📸 Screenshot:** *Cloudflare DNS with orange cloud proxy enabled on both records*

### Step 7 — Confirm Everything is Working

```bash
nslookup heros.com.ng 8.8.8.8
```

With the orange cloud on, this will return Cloudflare's own proxy IPs (something like `172.67.x.x` and `104.21.x.x`) instead of your Azure IP. That is exactly what you want — it means all traffic is flowing through Cloudflare.

Open `https://heros.com.ng` in your browser. The app should load with a valid HTTPS padlock in the address bar.

> **📸 Screenshot:** *Browser showing heros.com.ng fully loaded with HTTPS*

> **📸 Screenshot:** *Successful login to the web application*

---

## Verification Commands

These are the commands to check that every part of the stack is healthy after deployment.

### All pods across all namespaces

```bash
kubectl get pods -A
```

Everything should be in `Running` state. Here is what the full pod list looks like on a healthy deployment:

| Namespace | Pod |
|---|---|
| cert-manager | cert-manager-* |
| cert-manager | cert-manager-cainjector-* |
| cert-manager | cert-manager-webhook-* |
| cloudflare-tunnel | cloudflared-* |
| ingress-nginx | ingress-nginx-controller-* |
| monitoring | alertmanager-* |
| monitoring | monitoring-grafana-* |
| monitoring | monitoring-kube-prometheus-operator-* |
| monitoring | monitoring-kube-state-metrics-* |
| monitoring | monitoring-prometheus-node-exporter-* (×2 nodes) |
| monitoring | prometheus-* |
| tooling | tooling-db-0 |
| tooling | tooling-web-web-* (×2 replicas) |

> **📸 Screenshot:** *kubectl get pods -A with all pods in Running state*

### TLS certificate status

```bash
kubectl get certificate -n tooling
kubectl describe certificate tooling-web-tls -n tooling
```

The READY column should say `True`. It will look like this when it is healthy:

```
NAME              READY   SECRET            AGE
tooling-web-tls   True    tooling-web-tls   10m
```

> **📸 Screenshot:** *kubectl get certificate output showing READY: True*

### cert-manager health

```bash
kubectl get pods -n cert-manager
kubectl logs -n cert-manager deploy/cert-manager --tail=30
```

### Cloudflare Tunnel connection status

```bash
kubectl get pods -n cloudflare-tunnel
kubectl logs -n cloudflare-tunnel deployment/cloudflared --tail=20
```

Look for a line that says `Registered tunnel connection` in the logs. That tells you the pod has successfully made its outbound connection to Cloudflare's network and is ready to serve traffic.

> **📸 Screenshot:** *cloudflared logs showing Registered tunnel connection*

### Ingress and services

```bash
kubectl get ingress -n tooling
kubectl get svc -n ingress-nginx
kubectl get svc -n tooling
```

### Force cert-manager to retry a stuck certificate

If the certificate is sitting at `READY: False` and not moving, delete the related resources and cert-manager will recreate them automatically:

```bash
kubectl delete certificate tooling-web-tls -n tooling
kubectl delete order --all -n tooling
kubectl delete challenge --all -n tooling
```

Watch the recovery:

```bash
kubectl get certificate -n tooling -w
kubectl get challenge -n tooling
```

### Test the app from inside the cluster

This spins up a temporary pod, fires a curl request at the app service, prints the result, and cleans itself up:

```bash
kubectl run curl-test \
  --image=curlimages/curl \
  --rm -it --restart=Never \
  -n tooling -- \
  curl -v http://tooling-web-service:80 --max-time 10
```

If this returns HTML or a redirect, the app is alive and the problem is somewhere on the external path — DNS, ISP, or Cloudflare config. If this also fails, the issue is inside the cluster.

### Grafana monitoring dashboard

```bash
kubectl get svc -n monitoring | grep grafana
```

Take the external IP from that output and open it in your browser on port 80. Log in with username `admin` and the `GRAFANA_PASSWORD` from your GitHub secrets. You will see live metrics for all tooling pods — CPU, memory, disk, and network.

> **📸 Screenshot:** *Grafana Kubernetes dashboard showing live pod metrics*

---

## The Troubleshooting Journey

This did not deploy cleanly the first time and that is the honest truth. Here is what went wrong across the sessions and what actually fixed each thing. The full session logs are in the `/docs` folder.

**cert-manager installed before ingress-nginx**

The first version of the pipeline had cert-manager installing before the NGINX Ingress Controller existed. ACME challenges need a working ingress with an external IP to route challenge traffic. Without it, every certificate attempt failed immediately. The fix was restructuring the pipeline so ingress-nginx goes first, gets its IP, waits for DNS, and only then hands off to cert-manager.

**NSG rules with empty port ranges**

The Azure CLI flag `--destination-port-ranges` (plural) was silently creating NSG rules with no ports defined in the pipeline environment. The rules showed up in the list looking correct, but they allowed no traffic whatsoever. The fix was adding `load_balancer_sku = "standard"` to the Terraform AKS network profile so the Standard Load Balancer handles NSG rules automatically and correctly.

**HTTP-01 challenge timing out permanently**

Let's Encrypt uses port 80 for HTTP-01 challenges. Azure East US IP ranges were being blocked or filtered before requests could reach the cluster, so every challenge attempt timed out. Switching to DNS-01 via Cloudflare's API solved this entirely — the challenge no longer needs port 80. cert-manager creates a TXT record in Cloudflare DNS, Let's Encrypt reads it, and the certificate issues.

**Azure East US IP blocked at the ISP level**

After the TLS certificate successfully issued, the app still would not load in a browser or on mobile data. The ingress IP `20.231.250.154` was being blocked by Nigerian ISPs. Internal cluster curl worked fine, confirming everything inside Azure was healthy. The block was purely on the path between local machines and the Azure IP.

**Region migration from East US to West Europe**

Changed the Terraform location from East US to West Europe, destroyed and rebuilt the entire infrastructure. The new West Europe IP `4.175.121.155` was also blocked by the same ISPs. At this point it was clear the Azure IP itself was never going to be the answer.

**Cloudflare Tunnel**

Rather than keep trying to make the Azure IP reachable, a Cloudflare Tunnel was deployed inside the cluster. The cloudflared pod makes an outbound connection from inside AKS to Cloudflare's edge. Users hit Cloudflare, Cloudflare routes through the tunnel, and the request lands inside the cluster without any inbound connection ever touching the Azure IP. After this, `https://heros.com.ng` loaded in the browser with a valid certificate and the login worked.

> **📸 Screenshot:** *Successful login proof — app fully accessible at heros.com.ng*

---

## Repository Structure

```
tooling/
├── .github/
│   └── workflows/
│       ├── deploy.yml          # CI/CD workflow — build, scan, and deploy
│       └── terraform.yaml      # Infrastructure provisioning workflow
├── helm/
│   └── tooling-web/            # Helm chart for the application
│       ├── templates/
│       │   ├── db-and-svc.yaml     # MySQL StatefulSet and Service
│       │   ├── deployment.yaml     # App Deployment manifest
│       │   ├── hpa.yaml            # Horizontal Pod Autoscaler
│       │   └── ingress.yaml        # Ingress with TLS annotation
│       ├── Chart.yaml
│       └── values.yaml
├── html/                       # Application source files
├── k8s/                        # Standalone Kubernetes manifests
├── terraform/
│   ├── backend.tf              # Remote state in Azure Blob Storage
│   ├── main.tf                 # AKS, ACR, and networking resources
│   └── outputs.tf              # Outputs consumed by GitHub Actions
├── .gitignore
├── apache-config.conf          # Apache virtual host configuration
├── cloudflared.yaml            # Cloudflare Tunnel deployment manifest
├── docker-compose.yml          # Local development compose file
├── Dockerfile                  # Container image definition
├── ingress-nginx-svc-backup.yaml  # Backup ingress service manifest
├── Jenkinsfile                 # Jenkins pipeline (reference only)
├── LICENSE
├── README.md
├── start-apache                # Apache startup script
└── tooling-db.sql              # Database schema
```

---

## Key Takeaways for Anyone Repeating This

Start with DNS-01 instead of HTTP-01 if you are deploying from Nigeria or anywhere Azure IP ranges tend to get filtered. HTTP-01 looks simple but it has a hard dependency on port 80 being reachable from Let's Encrypt's servers, and that is a fight you will not win in this network environment. DNS-01 via Cloudflare sidesteps the whole problem.

The pipeline order is not negotiable. cert-manager depends on ingress-nginx and on DNS being live before it can issue anything. Skipping or reordering those steps produces errors that look like config problems but are actually sequencing problems.

Cloudflare Tunnel is genuinely the right architecture here, not a last resort. Having your cloud IP hidden behind a tunnel is a security improvement regardless of ISP filtering. Nobody can port-scan or directly attack an IP that has nothing listening on it.

Before spending time debugging Azure config, run the internal curl test. If the cluster can reach the app but external access is broken, the issue is outside Azure and you should be looking at DNS, ISP routing, or Cloudflare settings instead.

---

*Built and documented by Christopher Ojedayo*  
*Repository: [https://github.com/kristarking/tooling-project](https://github.com/kristarking/tooling-project)*  
*Connect: [linkedin.com/in/christopherojedayo](https://www.linkedin.com/in/christopherojedayo/)*
