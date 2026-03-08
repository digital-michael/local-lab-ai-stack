
#!/usr/bin/env bash
echo "Validating environment..."
command -v podman || echo "Podman not installed"
command -v nvidia-smi || echo "GPU not detected"
echo "Validation finished."
