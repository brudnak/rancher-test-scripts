# HA Port Scan

[⬅️ GO BACK](../README.md)

### Basic usage (assumes local.yaml is in current directory)

```sh
curl -s url$$$ | bash
```

### Specify a different kubeconfig file

```sh
curl -s url$$$ | KUBECONFIG_ENV=/path/to/your/kubeconfig.yaml bash
```

### Check a different port (example: port 8080, hex 1F90)

```sh
curl -s url$$$ | PORT_TO_CHECK=8080 PORT_HEX=1F90 bash
```

### Specify a different namespace

```sh
curl -s url$$$ | NAMESPACE=your-namespace bash
```