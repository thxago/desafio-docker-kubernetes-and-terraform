# Mural de Recados — Docker, Kubernetes e Terraform

Entrega do desafio [Do compose ao cluster](https://github.com/devfullcycle/desafio-docker-kubernetes-and-terraform).
**Fork público:** https://github.com/thxago/desafio-docker-kubernetes-and-terraform

Um único `terraform apply` constrói as imagens, cria o cluster kind, carrega as
imagens, instala Traefik e implanta o Mural no namespace `mural`. O segundo apply
não altera recursos; `terraform destroy` remove o ambiente e suas imagens exclusivas.
O código original de `app/api/` e `app/web/` foi preservado.

## Pré-requisitos

- Windows, Git e PowerShell 7 (`pwsh`), com Docker Desktop usando containers Linux.
- Terraform >= 1.9 e < 2.0; kind 0.30.0 no PATH.
- kubectl compatível com Kubernetes 1.34 e Helm 3.19.0 para diagnóstico e execução manual do chart.
- Pelo menos 5 GiB livres antes do provisionamento; reserve mais se não houver caches.
- Portas locais 80/443 disponíveis e acesso à internet para providers, imagens e chart.
  O navegador também precisa acessar `esm.sh`, usado pelo front.

Validado em linux/amd64, Docker Engine 28.4.0 e Terraform 1.13.5. Os providers
kind 0.13.0, Helm 3.3.0 e Kubernetes 3.5.0 estão fixados no lockfile versionado.

## Executar do zero

Clone o fork e, em PowerShell 7, gere uma credencial local sem imprimir a senha:

```powershell
git clone https://github.com/thxago/desafio-docker-kubernetes-and-terraform.git
Set-Location desafio-docker-kubernetes-and-terraform

if (Test-Path .env) { throw ".env já existe; preserve a credencial atual." }
$bytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$password = [BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()
Get-Content .env.example |
    ForEach-Object { $_ -replace '^POSTGRES_PASSWORD=$', "POSTGRES_PASSWORD=$password" } |
    Set-Content .env -Encoding ascii
Remove-Variable password, bytes

$config = ConvertFrom-StringData (Get-Content .env -Raw)
$env:TF_VAR_postgres_password = $config.POSTGRES_PASSWORD
$env:TF_VAR_postgres_username = $config.POSTGRES_USER
$env:TF_VAR_postgres_database = $config.POSTGRES_DB
Remove-Variable config

Set-Location infra\terraform
if (-not (Test-Path terraform.tfvars)) {
    Copy-Item terraform.tfvars.example terraform.tfvars
}
terraform init
terraform fmt -check
terraform validate
terraform apply
terraform output -raw url
```

Abra **http://mural.localtest.me** e publique um recado. Não é preciso subir o
Compose, construir imagens ou criar o cluster manualmente antes desse apply.

Se o encaminhamento local em 80/443 não funcionar, configure `http_port = 18080`
e `https_port = 18443` no `terraform.tfvars` privado **antes do primeiro apply**.
Nesse caso, o acesso será **http://mural.localtest.me:18080**. Use os mesmos
valores e credencial durante todo o ciclo. Alterar portas de um cluster existente
substitui o cluster e descarta seus dados.

No mesmo terminal e diretório:

```powershell
terraform apply
# Esperado: 0 added, 0 changed, 0 destroyed
terraform destroy
Remove-Item Env:\TF_VAR_postgres_password
Remove-Item Env:\TF_VAR_postgres_username
Remove-Item Env:\TF_VAR_postgres_database
```

`.env`, tfvars privados, plans, state e kubeconfig são ignorados pelo Git.
**Sensitive não criptografa o state:** ele e seus backups contêm a senha e a chave
privada do cluster. Proteja-os e não publique saídas de Secrets ou configurações
com credenciais expandidas. Reutilize a senha: mudar uma variável não troca a senha
de um Postgres já inicializado.

## Decisões

| Área | Solução |
|---|---|
| API | Build Go multi-stage estático, runtime `scratch`, certificados CA e usuário não root; sem fontes ou toolchain na imagem final. |
| Front | nginx com `API_UPSTREAM` processado no boot; a mesma imagem funciona em ambientes diferentes sem recompilar. |
| Banco | Postgres em StatefulSet com PVC. Recriar o pod preserva recados; excluir o cluster local descarta os volumes. |
| Migrações | Job e ConfigMap por revisão, SQLs em ordem numa transação. InitContainer aguarda conclusão antes de iniciar a API; TTL limpa Jobs encerrados. Sem hook pós-instalação que bloqueie `--wait`. |
| Saúde e recursos | `/healthz` na liveness e `/readyz` na readiness da API; probes próprias para front/banco e requests/limits em todos os workloads. |
| Configuração | ConfigMaps para dados não sensíveis; Secret criado pelo Terraform e injetado por `secretKeyRef`. |
| Rede | Traefik, label `ingress-ready=true` e NodePorts mapeados para o host; `/` vai ao front e `/api` à API. O acesso validado é HTTP, sem certificado TLS configurado. |
| Idempotência | Tags e gatilhos por hash de conteúdo, sem timestamps. Destroy remove apenas recursos e tags exclusivos; preserva imagens oficiais, caches e recursos compartilhados. |

## Imagem mínima e evidências

Medições reais em 2026-11-13, Docker Desktop 4.47.0, linux/amd64. A referência é
a imagem oficial usada com `go run` no Compose; o código ali é montado como volume.

| Imagem | `docker image ls` | `docker image inspect .Size` |
|---|---:|---:|
| `golang:1.23-alpine` — antes | 370 MB | 78.165.804 bytes |
| `mural-api:local` — depois | 13,1 MB | 3.506.616 bytes |
| `mural-web:local` | 73,6 MB | 20.980.836 bytes |

Compare valores da mesma coluna: o image store do Docker Desktop apresenta
métricas diferentes nesses comandos. Pela listagem, a API ficou **96,5% menor**.
Para reproduzir, execute na raiz:

```powershell
docker build -f app\docker\api.Dockerfile -t mural-api:local .
docker build -f app\docker\web.Dockerfile -t mural-web:local .
docker image ls golang:1.23-alpine
docker image ls mural-api:local
docker image ls mural-web:local
docker image inspect golang:1.23-alpine mural-api:local mural-web:local --format '{{.RepoTags}} {{.Size}}'
```

O ciclo completo foi validado em **mural.localtest.me:18080**: primeiro apply
com **8 recursos criados**, segundo apply **0/0/0** e destroy com **8 removidos**.
O navegador publicou e listou recados; o recado persistiu após recriar o pod do
Postgres; a indisponibilidade do banco não reiniciou a API. A validação usou
portas alternativas por uma limitação local de encaminhamento em 80; os defaults
da entrega continuam 80/443. [Roteiro e resultados completos](infra/validacao.md).

## Estrutura e guias

Dockerfiles em `app/docker/`, chart em `infra/helm/mural/` e maestro em
`infra/terraform/`. A [arquitetura-alvo](docs/arquitetura.md) descreve a integração.

- [Compose de aprendizado](infra/compose.md): quatro serviços com imagens oficiais;
  não substitui a entrega final nem é pré-requisito do Terraform.
- [Executar imagens no Compose](infra/docker-compose.images.yml): variante para validar
  os Dockerfiles, usando `docker compose -f docker-compose.yml -f infra\docker-compose.images.yml up --build`.
- [Helm manual no kind](infra/helm.md): instalação, upgrades, probes e persistência.
- [Terraform detalhado](infra/terraform.md): entradas, credenciais, limpeza e limitações.
- [Validação ponta a ponta](infra/validacao.md): comandos e evidências sem segredos.
- [Bônus: HPA, carga e atalhos](infra/bonus.md): metrics-server opcional, k6 e automação PowerShell.

## Bônus opcionais

Habilite `enable_autoscaling = true` conforme [o guia de bônus](infra/bonus.md)
para provisionar metrics-server e o HPA da API pelo mesmo Terraform. O padrão
continua sendo o fluxo obrigatório com réplicas fixas.

Com a credencial e os tfvars privados já configurados, na raiz:

```powershell
pwsh -NoProfile -File .\infra\mural.ps1 up
pwsh -NoProfile -File .\infra\mural.ps1 load
pwsh -NoProfile -File .\infra\mural.ps1 down
```

Os atalhos não substituem o maestro; `load` exige k6 e kubectl, testa `/api/messages`
e registra amostras de réplicas Ready. A escala em um único node local é ilustrativa.

Na validação real, a API escalou de **2 para 5 réplicas Ready** com 40 usuários
virtuais durante 180 segundos, sem falhas HTTP. O segundo `up` não alterou recursos
e `down` removeu os 9 recursos do ambiente com bônus.