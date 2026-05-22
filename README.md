# Tooling Web App — Production Deployment on Azure Kubernetes Service

**Author:** Christopher Ojedayo  
**Domain:** [https://heros.com.ng](https://heros.com.ng)  
**Stack:** Azure · AKS · Terraform · GitHub Actions · Docker · Helm · cert-manager · Cloudflare · Prometheus · Grafana

---

## What This Project Is

This is a production-grade deployment of a web application on Azure Kubernetes Service. The entire infrastructure is provisioned with Terraform, the application is containerized and stored in Azure Container Registry, and every deployment happens automatically through a GitHub Actions CI/CD pipeline. The app runs behind an NGINX Ingress Controller with TLS certificates issued by Let's Encrypt via cert-manager, and traffic reaches it through a Cloudflare Tunnel that bypasses direct IP exposure entirely.

The project went through real-world troubleshooting across multiple sessions — NSG rule bugs, ACME challenge failures, ISP-level IP blocking, and a full region migration from East US to West Europe. Every one of those issues is documented in this README so you understand not just how to deploy it, but what can go wrong and why.

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

**TLS flow:** cert-manager issues certificates from Let's Encrypt using DNS-01 challenge via Cloudflare API. The tunnel handles all inbound traffic so the Azure LoadBalancer IP never needs to be directly reachable.

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

Before you attempt this deployment, make sure the following are ready on your end:

**Accounts**

You need an active Azure account with a valid subscription. This project creates resources that incur costs — AKS, ACR, Load Balancer, storage. Tear things down when you are done if you are not using them.

You need a GitHub account with this repo forked or cloned into your own account. The CI/CD pipeline runs on GitHub Actions and needs secrets added to your repo settings.

You need a Cloudflare account (free plan is enough). Your domain must be using Cloudflare's nameservers. This is required for both the DNS-01 TLS challenge and the Cloudflare Tunnel.

**Tools to install locally**

- Azure CLI (`az`) — for authenticating and running the service principal command
- kubectl — for connecting to and inspecting your AKS cluster
- Terraform — for understanding and optionally modifying the infrastructure code
- Helm — if you want to manually upgrade or inspect the Helm chart
- Git — for cloning the repo and triggering the pipeline

**Domain**

You need a domain name with nameservers pointed to Cloudflare. This project uses `heros.com.ng`. Anywhere you see that domain in this README, replace it with your own.

---

## Cloudflare Setup — Step by Step

Cloudflare does two jobs in this project. First, it handles DNS and TLS certificate issuance via its API (so cert-manager can complete Let's Encrypt DNS-01 challenges without port 80 ever being involved). Second, it runs a tunnel so traffic reaches your app inside AKS without your Azure IP ever being directly exposed to the internet.

### Step 1 — Create a Cloudflare Account and Add Your Domain

Go to [cloudflare.com](https://cloudflare.com) and sign up. Once logged in, click **Add a Site** and enter your domain name. Choose the Free plan. Cloudflare will scan your existing DNS records and then give you two nameserver addresses (they look like `crystal.ns.cloudflare.com` and `milan.ns.cloudflare.com`). Go to your domain registrar and replace your current nameservers with these two. It can take up to 24 hours to propagate but is usually faster.

> **📸 Screenshot:** *Cloudflare dashboard showing nameservers*

### Step 2 — Add Your DNS Records

Once your domain is active on Cloudflare, go to **DNS** and add these records:

| Type | Name | Value | TTL | Proxy |
|---|---|---|---|---|
| A | @ | `<your-nginx-ingress-IP>` | Auto | Grey cloud (DNS only) during pipeline |
| A | www | `<your-nginx-ingress-IP>` | Auto | Grey cloud during pipeline |

Keep the proxy **off (grey cloud)** while the pipeline is running and during certificate issuance. The pipeline's DNS wait step needs to resolve your actual Azure IP, not Cloudflare's proxy IPs. After the certificate is issued and the tunnel is deployed, you will flip these to orange cloud.

> **📸 Screenshot:** *Cloudflare DNS records showing A records with grey cloud*

### Step 3 — Create a Cloudflare API Token

This token is what cert-manager uses to create and delete DNS TXT records during the Let's Encrypt DNS-01 challenge.

1. In the Cloudflare dashboard, click your profile icon (top right) and go to **My Profile**
2. Click **API Tokens**, then **Create Token**
3. Click **Use template** next to **Edit zone DNS**
4. Under **Zone Resources**, select your specific domain from the dropdown
5. Click **Continue to summary**, then **Create Token**
6. Copy the token immediately — Cloudflare only shows it once

This token goes into your GitHub Actions secrets as `CLOUDFLARE_API_TOKEN`.

> **📸 Screenshot:** *Cloudflare API token creation screen*

### Step 4 — Create a Cloudflare Tunnel

The tunnel is what makes traffic reach your app even when Nigerian ISPs or Cloudflare's own proxy servers cannot reach your Azure IP directly. The cloudflared pod inside your cluster makes an outbound connection to Cloudflare. Traffic flows from the user, to Cloudflare's edge, through that outbound tunnel connection, and into your cluster. Your Azure IP never needs to be directly reachable.

1. In the Cloudflare dashboard, go to **Zero Trust** (left sidebar)
2. If it asks you to set up a team name, pick anything — this does not affect billing
3. Go to **Networks** → **Tunnels**
4. Click **Create a Tunnel**, choose **Cloudflared**, and name it something like `tooling-aks`
5. On the next screen, choose **Docker** as the environment — this gives you a `docker run` command with your tunnel token embedded in it. You only need the token part (the long string starting with `eyJ...`)
6. Copy that token and save it somewhere safe

After the tunnel is created, you will configure its public hostname routes. Do that after you have deployed the cloudflared pod to your cluster (covered in the deployment steps below).

> **📸 Screenshot:** *Cloudflare Zero Trust tunnel creation screen*

---

## GitHub Secrets Setup

Go to your GitHub repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**. Add each of these:

### AZURE_CREDENTIALS

This is the JSON output from creating a service principal with Owner role. Run this in your terminal (replace `<your-subscription-id>`):

```bash
az login

az ad sp create-for-rbac \
  --name tooling-auth-v2 \
  --role Owner \
  --scopes /subscriptions/<your-subscription-id> \
  --sdk-auth
```

Copy the entire JSON output that looks like `{ "clientId": "...", "clientSecret": "...", ... }` and paste that as the value of this secret.

> **📸 Screenshot:** *GitHub repo secrets page showing all secrets added*

### CLOUDFLARE_API_TOKEN

Paste the Cloudflare API token you created in the Cloudflare setup step above.

### GRAFANA_PASSWORD

Choose any password you want for the Grafana monitoring dashboard login.

### MYSQL_PASSWORD

The password for the MySQL application user. This project uses `admin` — change it to something stronger for your own deployment.

### MYSQL_ROOT_PASSWORD

The MySQL root password. This project uses `admin` — again, change for your own deployment.

---

## Terraform Remote State Setup

Before the pipeline can run Terraform, it needs a place to store the Terraform state file. This is a storage account in Azure. Run these commands once before your first push:

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

> **Important:** The location here is `westeurope`, matching the AKS cluster region. If you change the AKS region in `terraform/main.tf`, update this command to match.

---

## How the CI/CD Pipeline Works

The GitHub Actions pipeline has two workflows that trigger on push to `main`. The **Terraform workflow** provisions or updates the infrastructure. The **CI/CD workflow** builds, scans, and deploys the application.

When you push, here is the order of what happens in the deployment job:

1. Namespaces are created first — `tooling`, `ingress-nginx`, `cert-manager`, `monitoring`, `cloudflare-tunnel`
2. NGINX Ingress Controller is installed and the external IP is printed in the pipeline logs
3. The pipeline waits for DNS propagation — it keeps checking every 30 seconds until both `heros.com.ng` and `www.heros.com.ng` resolve to the ingress IP
4. cert-manager is installed after DNS is confirmed, not before
5. All three cert-manager pods (`cert-manager`, `cert-manager-webhook`, `cert-manager-cainjector`) must be fully ready before the next step
6. The Cloudflare API token secret is created in the `cert-manager` namespace
7. The ClusterIssuer is applied using a polling loop (not `kubectl wait`, which is unreliable for this)
8. Database secrets are created
9. The app is deployed via Helm
10. The database schema is imported (with error suppression for re-deploys where tables already exist)
11. The Prometheus and Grafana monitoring stack is installed

This order is non-negotiable. Installing cert-manager before ingress-nginx, or cert-manager before DNS propagation, will cause certificate failures that are painful to debug.

> **📸 Screenshot:** *GitHub Actions pipeline showing all steps passed*

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

Both workflows will trigger automatically.

### Step 2 — Watch the Pipeline and Update DNS

When the pipeline reaches the **Install ingress-nginx** step, it will print the external IP it was assigned. Copy that IP and update your Cloudflare DNS A records immediately (both `@` and `www`). Keep them on grey cloud (DNS only) at this point.

The pipeline will then sit in the DNS propagation wait loop until `nslookup heros.com.ng 8.8.8.8` returns that IP. Once DNS is confirmed, it moves forward automatically.

> **📸 Screenshot:** *Pipeline logs showing external IP being printed*

### Step 3 — Connect to Your Cluster

Once the pipeline completes the AKS deploy step, you can connect to the cluster:

```bash
az aks get-credentials --resource-group tooling-rg --name tooling-aks
```

### Step 4 — Deploy the Cloudflare Tunnel

After the pipeline finishes, the cloudflared pod needs your tunnel token. Create the token secret in the cluster:

```bash
kubectl create namespace cloudflare-tunnel --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic cloudflare-tunnel-token \
  --from-literal=token='<your-tunnel-token-from-cloudflare>' \
  -n cloudflare-tunnel
```

Create a file called `cloudflared.yaml` with this content (use Notepad on Windows — Git Bash has heredoc issues):

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

### Step 5 — Configure Tunnel Hostname Routes

Back in Cloudflare → Zero Trust → Networks → Tunnels → your tunnel → **Public Hostnames**:

| Subdomain | Domain | Path | Service |
|---|---|---|---|
| (empty) | heros.com.ng | | `http://tooling-web-service.tooling.svc.cluster.local:80` |
| www | heros.com.ng | | `http://tooling-web-service.tooling.svc.cluster.local:80` |

The URL format `tooling-web-service.tooling.svc.cluster.local:80` is Kubernetes internal DNS. The cloudflared pod runs inside the cluster, so it can reach any service this way. The format is always `<service-name>.<namespace>.svc.cluster.local:<port>`.

### Step 6 — Flip Cloudflare to Orange Cloud

In Cloudflare DNS, click the cloud icon next to your A records to switch them from grey (DNS only) to orange (proxied). Also go to **SSL/TLS** and set the mode to **Full**.

> **📸 Screenshot:** *Cloudflare DNS records showing orange cloud enabled*

### Step 7 — Verify DNS and Test

```bash
nslookup heros.com.ng 8.8.8.8
```

With orange cloud on, this should return Cloudflare proxy IPs like `172.67.x.x` and `104.21.x.x`. That is correct — it means traffic is flowing through Cloudflare.

Open `https://heros.com.ng` in a browser. You should see the app with a valid HTTPS padlock.

> **📸 Screenshot:** *Browser showing heros.com.ng with HTTPS and the app loaded*

> **📸 Screenshot:** *Successful login to the web app*

---

## Verification Commands

Use these to confirm everything is healthy after deployment.

### Check all pods across all namespaces

```bash
kubectl get pods -A
```

All pods should show `Running`. The expected pods are:

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
| monitoring | monitoring-prometheus-node-exporter-* (×2) |
| monitoring | prometheus-* |
| tooling | tooling-db-0 |
| tooling | tooling-web-web-* (×2 replicas) |

> **📸 Screenshot:** *`kubectl get pods -A` output with all pods Running*

### Check TLS certificate

```bash
kubectl get certificate -n tooling
kubectl describe certificate tooling-web-tls -n tooling
```

The `READY` column should show `True`. A successful certificate looks like:

```
NAME              READY   SECRET            AGE
tooling-web-tls   True    tooling-web-tls   10m
```

> **📸 Screenshot:** *kubectl get certificate output showing READY: True*

### Check cert-manager is healthy

```bash
kubectl get pods -n cert-manager
kubectl logs -n cert-manager deploy/cert-manager --tail=30
```

### Check the Cloudflare Tunnel is connected

```bash
kubectl get pods -n cloudflare-tunnel
kubectl logs -n cloudflare-tunnel deployment/cloudflared --tail=20
```

In the logs you should see a line containing `Registered tunnel connection`. That confirms cloudflared has made a live outbound connection to Cloudflare's network.

> **📸 Screenshot:** *cloudflared pod logs showing "Registered tunnel connection"*

### Check ingress and services

```bash
kubectl get ingress -n tooling
kubectl get svc -n ingress-nginx
kubectl get svc -n tooling
```

### Force cert-manager to retry if something is stuck

If the certificate is stuck at `READY: False`, delete everything and let cert-manager start fresh:

```bash
kubectl delete certificate tooling-web-tls -n tooling
kubectl delete order --all -n tooling
kubectl delete challenge --all -n tooling
```

cert-manager recreates the certificate automatically because of the annotation on the Ingress resource. Watch it recover:

```bash
kubectl get certificate -n tooling -w
kubectl get challenge -n tooling
```

### Test the app internally from inside the cluster

This command spins up a temporary curl pod inside the cluster, runs a request to the app service, and then deletes itself:

```bash
kubectl run curl-test \
  --image=curlimages/curl \
  --rm -it --restart=Never \
  -n tooling -- \
  curl -v http://tooling-web-service:80 --max-time 10
```

If this returns HTML or an HTTP redirect, the app is alive. If external access is broken but this works, the problem is outside the cluster (DNS, ISP, Cloudflare config).

### Check Grafana monitoring

Grafana runs on its own LoadBalancer service in the `monitoring` namespace:

```bash
kubectl get svc -n monitoring | grep grafana
```

Take the external IP from that output and open it in your browser on port 80. Log in with username `admin` and the `GRAFANA_PASSWORD` you set in GitHub secrets. The Kubernetes dashboards will show live CPU, memory, disk, and network metrics for all your tooling pods.

> **📸 Screenshot:** *Grafana dashboard showing Kubernetes metrics*

---

## The Troubleshooting Journey

This deployment did not go smoothly on the first try and that is entirely the point. Here is a summary of the major issues encountered across the session dates and what resolved them. The full logs are in the `/docs` folder.

**Wrong pipeline order (cert-manager before ingress-nginx)**  
cert-manager was installed before NGINX Ingress Controller in the first version of the pipeline. This meant ACME challenges had nowhere to go. Fix: ingress-nginx must install first, get its external IP, wait for DNS propagation, and only then install cert-manager.

**NSG rules created with empty port ranges**  
The Azure CLI flag `--destination-port-ranges` (plural) silently creates NSG rules with no ports defined in some pipeline environments, allowing no traffic at all despite the rules appearing in the list. Fix: added `load_balancer_sku = "standard"` to the Terraform AKS network profile, which lets the AKS Standard Load Balancer manage NSG rules automatically.

**HTTP-01 challenge failing permanently**  
Let's Encrypt uses port 80 for HTTP-01 challenges. Azure East US IP ranges were unreachable from Let's Encrypt's validation servers in this environment. Fix: migrated DNS to Cloudflare and switched to DNS-01 challenge type. The ClusterIssuer now uses Cloudflare's API to create TXT records instead of requiring port 80.

**Azure East US IP blocked by Nigerian ISPs**  
Even after the TLS certificate issued successfully, the app was inaccessible from local browsers and mobile data. The Azure East US IP range `20.231.250.154` was blocked at the ISP level. Internal cluster curl worked fine — the problem was entirely on the client network path.

**Region migration from East US to West Europe**  
Changed `location = "East US"` to `location = "West Europe"` in `terraform/main.tf`, destroyed the old infrastructure, and ran a full redeploy. The new West Europe IP `4.175.121.155` was still blocked from Nigerian ISPs, which led to the tunnel solution.

**Cloudflare Tunnel as the final fix**  
Instead of trying to make the Azure IP reachable, a Cloudflare Tunnel was deployed inside the cluster. The cloudflared pod makes an outbound connection from inside AKS to Cloudflare's edge network. Traffic flows: user → Cloudflare → tunnel → cluster → app. The Azure IP never needs to accept any inbound connections from outside. With this in place, `https://heros.com.ng` became fully accessible with HTTPS confirmed in the browser.

> **📸 Screenshot:** *Proof of successful login — app running on heros.com.ng*

---

## Repository Structure

```
tooling-project/
├── .github/
│   └── workflows/
│       ├── terraform.yml       # Infrastructure provisioning workflow
│       └── ci-cd.yml           # Build, scan, and deploy workflow
├── helm/
│   └── tooling-web/            # Helm chart for the application
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
├── terraform/
│   ├── main.tf                 # AKS, ACR, networking resources
│   ├── variables.tf
│   ├── outputs.tf              # Outputs consumed by GitHub Actions
│   └── backend.tf              # Remote state in Azure Blob Storage
├── tooling-db.sql              # Database schema
├── Dockerfile
└── README.md
```

---

## Key Lessons for Anyone Repeating This

The certificate challenge type matters more than you think. HTTP-01 is the default and it requires port 80 to be reachable from Let's Encrypt's servers. In environments where Azure IPs are filtered — which is common across African ISPs — HTTP-01 will silently time out every time. Switch to DNS-01 from the start if you are deploying from Nigeria or a similar environment and using Cloudflare for your domain.

The order inside the pipeline is not flexible. cert-manager has hard dependencies on ingress-nginx and on DNS being live before it can do anything useful. Getting the sequencing wrong means certificates fail in ways that are confusing because the errors look like config problems.

Cloudflare Tunnel is not a workaround, it is the correct architecture for this kind of deployment. It eliminates the need for your cloud provider IP to be directly reachable, which is a real security advantage regardless of ISP filtering.

Run `kubectl run curl-test` before you start blaming your Azure config. If the internal curl works, your cluster is fine and the problem is on the network path between your machine and the Azure IP. That narrows the debugging space significantly.

---

*Built and documented by Christopher Ojedayo*  
*Repository: [https://github.com/kristarking/tooling-project](https://github.com/kristarking/tooling-project)*
