# Validacao do ciclo completo

Este roteiro valida a entrega sem alterar a aplicacao ou provisionar recursos
manualmente. Execute os pre-requisitos e a configuracao de credenciais de
[`terraform.md`](terraform.md), referenciados pelo README. Os comandos abaixo
partem de `infra/terraform/`, com as mesmas variaveis durante todo o ciclo.

## Ambiente inicial

Use um nome de cluster que nao exista e portas livres. Para a configuracao
padrao, confirme ausencia de `mural-terraform`, de state com recursos e de
imagens exclusivas de uma execucao anterior:

```powershell
kind get clusters
docker ps -a --filter "label=io.x-k8s.kind.cluster=mural-terraform"
docker image ls "mural-terraform-*"
```

Se houver state ou recursos de uma execucao anterior, confira quem os gerencia
e encerre essa instalacao com seu proprio `terraform destroy`. Nao apague state
de um ambiente ativo, nao use prune e nao remova recursos de outros projetos.
Caches oficiais e plugins podem permanecer: ambiente limpo significa ausencia
dos recursos gerenciados desta instalacao, nao descarte de caches compartilhados.

Se as portas locais padrao nao encaminharem o trafego nesta maquina, ajuste
`http_port = 18080` e `https_port = 18443` no `terraform.tfvars` privado **antes**
do primeiro apply, como permitido em `terraform.md`. Use esses mesmos valores
no segundo apply e destroy. O output URL incluira a porta; os defaults
versionados da entrega continuam 80/443.

## Primeiro apply e integracao

```powershell
terraform init
terraform fmt -check
terraform validate
terraform apply
$kubeconfig = terraform output -raw kubeconfig_path
$url = terraform output -raw url
$cluster = terraform output -raw cluster_name

kubectl --kubeconfig $kubeconfig get nodes
helm list --all-namespaces --kubeconfig $kubeconfig
kubectl --kubeconfig $kubeconfig -n mural get pods,services,ingress,pvc,jobs
kubectl --kubeconfig $kubeconfig -n mural logs job/mural-migrate-1
kubectl --kubeconfig $kubeconfig -n mural exec deployment/mural-web -- wget -q -O - http://mural-api/readyz
```

Confirme releases `mural` e `traefik` deployed; PVC Bound; Job Complete;
API e front Ready. O log deve mostrar `001_init.sql` antes de `002_seed.sql`.
O Ingress deve usar Traefik e rotear `/` ao Service web e `/api` ao Service API.

Abra `$url` no navegador. Confira o seed, publique um recado identificavel e
confirme sua presenca apos atualizar a pagina. A publicacao deve retornar
HTTP 201, e a listagem HTTP 200. Sem alterar o front, a chamada usa `/api/messages`:

```powershell
Invoke-RestMethod "$url/api/messages"
```

Nao e necessario expor banco ou API diretamente no host.

## Persistencia e probes

Registre os identificadores antes de recriar somente o pod do banco:

```powershell
$oldPostgres = kubectl --kubeconfig $kubeconfig -n mural get pod mural-postgres-0 -o jsonpath='{.metadata.uid}'
$oldPvc = kubectl --kubeconfig $kubeconfig -n mural get pvc data-mural-postgres-0 -o jsonpath='{.metadata.uid}'
kubectl --kubeconfig $kubeconfig -n mural delete pod mural-postgres-0
kubectl --kubeconfig $kubeconfig -n mural rollout status statefulset/mural-postgres --timeout=120s
kubectl --kubeconfig $kubeconfig -n mural rollout status deployment/mural-api --timeout=120s
$newPostgres = kubectl --kubeconfig $kubeconfig -n mural get pod mural-postgres-0 -o jsonpath='{.metadata.uid}'
$newPvc = kubectl --kubeconfig $kubeconfig -n mural get pvc data-mural-postgres-0 -o jsonpath='{.metadata.uid}'
if ($oldPostgres -eq $newPostgres -or $oldPvc -ne $newPvc) { throw "Recriacao/persistencia incorreta." }
```

Aguarde o novo pod Ready e atualize o navegador: o recado deve permanecer.
O PVC nao e apagado neste teste.

Confira as probes e recursos na especificacao dos pods, incluindo initContainers,
Job e Traefik. Todos devem ter requests/limits de CPU e memoria; API deve usar
`/healthz` na liveness e `/readyz` na readiness. `DATABASE_URL`, `PGPASSWORD` e
`POSTGRES_PASSWORD` devem usar `secretKeyRef`, nao `value` literal.

```powershell
kubectl --kubeconfig $kubeconfig -n mural get deployment mural-api mural-web -o yaml
kubectl --kubeconfig $kubeconfig -n mural get statefulset mural-postgres -o yaml
kubectl --kubeconfig $kubeconfig -n mural get job mural-migrate-1 -o yaml
kubectl --kubeconfig $kubeconfig -n traefik get deployment traefik -o yaml
```

Esses workloads contem referencias, nao a senha. **Nao publique** `kubectl get
secret -o yaml`, state, kubeconfig nem saidas que expandam credenciais.

Para comprovar a diferenca entre liveness e readiness, registre os pods e seus
contadores, interrompa apenas o StatefulSet do banco e consulte cada API por
seu IP interno a partir do front. O Service API deixa de rotear para pods NotReady:

```powershell
$apiPods = (kubectl --kubeconfig $kubeconfig -n mural get pods -l app.kubernetes.io/component=api -o json | ConvertFrom-Json).items
try {
    kubectl --kubeconfig $kubeconfig -n mural scale statefulset/mural-postgres --replicas=0
    kubectl --kubeconfig $kubeconfig -n mural wait --for=delete pod/mural-postgres-0 --timeout=60s
    Start-Sleep -Seconds 15
    foreach ($pod in $apiPods) {
        $endpoint = "http://$($pod.status.podIP):8080"
        kubectl --kubeconfig $kubeconfig -n mural exec deployment/mural-web -- wget -q -O - "$endpoint/healthz"
        if ($LASTEXITCODE -ne 0) { throw "Liveness falhou." }
        kubectl --kubeconfig $kubeconfig -n mural exec deployment/mural-web -- wget -q -O - "$endpoint/readyz"
        if ($LASTEXITCODE -eq 0) { throw "Readiness passou sem banco." }
        $after = kubectl --kubeconfig $kubeconfig -n mural get pod $pod.metadata.name -o json | ConvertFrom-Json
        if ($after.status.containerStatuses[0].ready -or $after.status.containerStatuses[0].restartCount -ne $pod.status.containerStatuses[0].restartCount) {
            throw "Readiness ou contagem de reinicios incorreta."
        }
    }
} finally {
    kubectl --kubeconfig $kubeconfig -n mural scale statefulset/mural-postgres --replicas=1
    kubectl --kubeconfig $kubeconfig -n mural rollout status statefulset/mural-postgres --timeout=120s
    kubectl --kubeconfig $kubeconfig -n mural rollout status deployment/mural-api --timeout=120s
}
```

Durante a interrupcao, `/healthz` deve responder `ok`, `/readyz` deve falhar e
a contagem de reinicios deve permanecer igual. Restaure o banco mesmo se uma
verificacao falhar. Se alterou a porta da API, substitua 8080 no teste.

## Segundo apply: idempotencia

Com o banco restaurado, registre node, pods, PVC e revisao Helm. Nao altere
entradas nem arquivos entre o primeiro e o segundo apply:

```powershell
$beforePods = (kubectl --kubeconfig $kubeconfig -n mural get pods -o json | ConvertFrom-Json).items.metadata.uid | Sort-Object
$beforePvc = kubectl --kubeconfig $kubeconfig -n mural get pvc data-mural-postgres-0 -o jsonpath='{.metadata.uid}'
$beforeNode = docker inspect "$cluster-control-plane" --format '{{.Id}}'
helm history mural --namespace mural --kubeconfig $kubeconfig
terraform apply
terraform plan -detailed-exitcode
if ($LASTEXITCODE -ne 0) { throw "Ha alteracoes pendentes ou erro no plan." }
$afterPods = (kubectl --kubeconfig $kubeconfig -n mural get pods -o json | ConvertFrom-Json).items.metadata.uid | Sort-Object
$afterPvc = kubectl --kubeconfig $kubeconfig -n mural get pvc data-mural-postgres-0 -o jsonpath='{.metadata.uid}'
$afterNode = docker inspect "$cluster-control-plane" --format '{{.Id}}'
if (($beforePods -join ",") -ne ($afterPods -join ",") -or $beforePvc -ne $afterPvc -or $beforeNode -ne $afterNode) {
    throw "Recursos foram recriados."
}
helm history mural --namespace mural --kubeconfig $kubeconfig
```

O apply deve retornar **0 added, 0 changed, 0 destroyed**, o plan exit code 0
e a revisao da release permanecer igual. O recado deve continuar disponivel.

## Destroy e revisao da entrega

Registre as tags exclusivas antes de destruir:

```powershell
$images = terraform output -json images | ConvertFrom-Json
terraform destroy
terraform state list
docker ps -a --filter "label=io.x-k8s.kind.cluster=$cluster"
docker image ls $images.api
docker image ls $images.web
if (Test-Path -LiteralPath $kubeconfig) { throw "Kubeconfig dedicado permaneceu." }
```

State sem recursos; cluster, tags exclusivas e kubeconfig ausentes. Imagens
oficiais, caches e recursos externos devem permanecer. O state vazio e seu
backup nao sao removidos automaticamente e continuam privados.

Confira `git status` e `git ls-files`: nenhum `.env` real, state, plan, arquivo
privado ou kubeconfig pode entrar na entrega. Preserve os arquivos originais
em `app/api/` e `app/web/`, e registre o tamanho real da API antes/depois usando
o mesmo metodo descrito no README.

## Evidencias executadas

Validacao em **2026-11-13**, Windows, Docker 28.4.0, Terraform 1.13.5,
kind 0.30.0, Helm 3.19.0, Kubernetes 1.34.0 e Edge headless. Foram usados
os valores de `terraform.tfvars.example`, com override de portas 18080/18443,
cluster `mural-terraform` e **http://mural.localtest.me:18080**, sem recursos
anteriores desse cluster. Providers e imagens oficiais estavam em cache.

Uma primeira tentativa em 80/443 provisionou workloads saudaveis e o NodePort
interno respondeu, mas o encaminhamento externo em 80 retornou resposta vazia.
Essa instalacao foi destruida antes de repetir o ciclo completo nas portas
alternativas. Nao houve mudanca nos defaults da infraestrutura.

| Verificacao | Resultado real |
|---|---|
| Inicializacao | `init`, `fmt -check` e `validate` passaram. |
| Primeiro apply | `8 added, 0 changed, 0 destroyed`. |
| Integracao | Traefik e Mural deployed; Services presentes; Ingress com rotas `/` e `/api`; Job concluido e API Ready. |
| Migracoes | `001_init.sql` antes de `002_seed.sql`; seed inserido e revisao 1 registrada. |
| Navegador | Seed exibido; recado publicado com HTTP 201 e listado com HTTP 200. |
| Persistencia | Pod Postgres com novo UID, PVC com mesmo UID e recado preservado. |
| Probes | Banco indisponivel: `/healthz` respondeu `ok`, `/readyz` falhou, API NotReady sem aumento de reinicios. Recuperacao concluida. |
| Recursos e credenciais | Requests/limits em API, front, Postgres, Job, initContainer e Traefik; dados sensiveis por `secretKeyRef`, ausentes de ConfigMaps/values Helm. |
| Segundo apply | `0 added, 0 changed, 0 destroyed`; plan exit code 0; node, pods e PVC sem recriacao, recado preservado. |
| Destroy | `8 destroyed`; state sem recursos; cluster, tags exclusivas e kubeconfig removidos. |
| Recursos externos | Containers externos, imagens compartilhadas e kubeconfig padrao permaneceram intactos. |
| Revisao de arquivos | Os 9 arquivos da API/front coincidem com o starter; arquivos versionados nao contem a credencial real, state, plans ou configuracoes privadas. |

Tambem foram medidos os tamanhos pelo mesmo campo `docker image inspect .Size`:
referencia `golang:1.23-alpine` com **78.165.804 bytes** e API construida pelo
Terraform com **3.506.669 bytes**. A pequena diferenca em relacao aos
3.506.616 bytes decorre da imagem com label de propriedade usado
na limpeza do Terraform. A tabela original do README conserva a medicao; nao mistura esses valores com o tamanho de `docker image ls`.

O cluster de validacao foi removido. O tfvars, state e backup temporarios
foram descartados somente apos verificar state sem recursos. O `.env` local
preexistente foi preservado e continua ignorado pelo Git.