kubectl create namespace argocd
kubectl apply --server-side  -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.4/manifests/install.yaml
kubectl apply -f argocd/root.yaml