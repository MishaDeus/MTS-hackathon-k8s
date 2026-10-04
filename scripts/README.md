# Scripts

- `setup.sh` — idempotent-ish bootstrap for the single-node WSL2 environment.
- `verify.sh` — validates Kubernetes, Cilium, nginx, Gateway API, MetalLB, Prometheus and Filebeat.

Before running from a new WSL shell:

```bash
source ~/.hackathon-k8s-env
```

Then:

```bash
./scripts/setup.sh
./scripts/verify.sh
```
