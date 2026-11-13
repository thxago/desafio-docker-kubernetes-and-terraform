# Mural no kind com Helm

Esta etapa implanta o chart manualmente para validar a arquitetura. O Terraform
sera o maestro na etapa seguinte; os comandos abaixo nao substituem essa entrega.
O codigo da API e do front permanece inalterado.

## Pre-requisitos

- Docker Desktop com engine Linux, espaco livre suficiente para as imagens e o cluster.
- kind 0.30.0, Helm 3.19.0 e kubectl compativel com Kubernetes 1.34.
- Imagens `mural-api:local` e `mural-web:local` construidas conforme o README.
- `.env` local criado conforme `infra/compose.md`.

Execute na raiz do repositorio. A configuracao `infra/kind-dev.yaml` usa um
unico node `kindest/node:v1.34.0`, label `ingress-ready=true` e portas locais
80/443, mapeadas aos NodePorts 30080/30443 do Traefik. Se essas portas estiverem
ocupadas, altere apenas os `hostPort` e inclua a porta HTTP no endereco do navegador.
Nao remova clusters ou recursos de outros projetos.

## Cluster e imagens

```powershell
kind create cluster --name mural-dev --config infra\kind-dev.yaml
docker pull --platform linux/amd64 postgres:16-alpine
docker pull --platform linux/amd64 traefik:v3.6.2
```

Carregue as imagens pelo Docker. Isso evita depender de downloads dentro do node,
que podem falhar em redes com certificados corporativos.
Use um arquivo temporario de plataforma unica para evitar erros de importacao
de indices multiarch com blobs de outras plataformas ausentes no Docker Desktop:

```powershell
$archive = Join-Path $env:TEMP "mural-dev-images-$([guid]::NewGuid()).tar"
try {
    docker image save --platform linux/amd64 -o $archive mural-api:local mural-web:local postgres:16-alpine traefik:v3.6.2
    if ($LASTEXITCODE -ne 0) { throw "Falha ao exportar imagens." }
    kind load image-archive $archive --name mural-dev
    if ($LASTEXITCODE -ne 0) { throw "Falha ao carregar imagens." }
} finally {
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive }
}
```

Esses comandos assumem linux/amd64. Em outra arquitetura, use uma plataforma
consistente no build, pull e exportacao. Reserve espaco tambem para o arquivo
temporario; nao desabilite validacao TLS para contornar problemas de certificado.

## Traefik

```powershell
helm upgrade --install traefik traefik --repo https://traefik.github.io/charts --version 37.4.0 --namespace traefik --create-namespace --kube-context kind-mural-dev --values infra\traefik-values.yaml --wait --timeout 5m
```

O chart Traefik 37.4.0 usa a imagem v3.6.2 carregada acima. O Service NodePort
disponibiliza as portas web/websecure; o Mural usa HTTP nesta etapa.

## Credencial privada e instalacao

Gere os valores privados a partir do `.env`, sem imprimir a senha:

```powershell
$config = ConvertFrom-StringData (Get-Content .env -Raw)
if ([string]::IsNullOrWhiteSpace($config.POSTGRES_PASSWORD)) { throw "Senha local ausente." }
@{
    postgres = @{
        username = $config.POSTGRES_USER
        database = $config.POSTGRES_DB
        password = $config.POSTGRES_PASSWORD
    }
} | ConvertTo-Json -Depth 4 | Set-Content infra\helm-values.private.json -Encoding ascii
Remove-Variable config
```

`infra/helm-values.private.json` e ignorado pelo Git. Reutilize a mesma credencial
nos upgrades: alterar um Secret nao altera automaticamente a senha de um banco
ja inicializado no PVC. Nao publique o arquivo, saidas de `helm get values`,
manifests renderizados com a senha real ou dados dos Secrets.

```powershell
helm lint infra\helm\mural --strict --values infra\helm-values.private.json
helm template mural infra\helm\mural --namespace mural --set postgres.existingSecret=render-check-secret
helm upgrade --install mural infra\helm\mural --namespace mural --create-namespace --kube-context kind-mural-dev --values infra\helm-values.private.json --wait --wait-for-jobs --timeout 5m
```

O Secret `render-check-secret` no comando de renderizacao e apenas uma referencia
ficticia para inspecionar YAML sem expor a senha; nao use essa configuracao na
instalacao. Na instalacao normal, Helm cria o Secret com chaves `password` e
`database-url`, e os workloads usam `secretKeyRef`.

Como alternativa, configure `postgres.existingSecret` para um Secret ja existente
no namespace `mural`, contendo essas duas chaves. A URL deve apontar ao Service
Postgres da release, normalmente `mural-postgres:5432`. Nessa modalidade, o chart
nao cria nem gerencia a credencial externa.

Abra **http://mural.localtest.me**, que resolve para loopback, e publique um recado.
O front usa React/htm de `esm.sh`, portanto o navegador precisa de internet.
O Ingress encaminha `/` ao front e `/api` diretamente a API, sem remover o prefixo.
O proxy nginx tambem permanece funcional dentro do cluster.

## Migracoes, probes e persistencia

Todas as migrations em `files/migrations/*.sql` sao aplicadas em ordem lexical
numa unica transacao, com `ON_ERROR_STOP`. O Job termina criando/atualizando a
tabela de controle de infraestrutura `mural_infra_migrations`, com nome da
release e revisao. A tabela da aplicacao e o seed nao ficam parcialmente visiveis
na primeira instalacao.

O Job se chama `mural-migrate-<revisao>` e usa um ConfigMap de migrations tambem
especifico da revisao. Isso evita reaproveitar arquivos removidos de uma
tentativa de upgrade que falhou. O initContainer da API aguarda a revisao
correta na tabela de controle antes de iniciar o binario. Assim, instalacao e
upgrade funcionam com `--wait --wait-for-jobs`, sem hooks que dependam de
recursos ainda nao criados. O upgrade cria um novo Job e remove o anterior de uma release bem-sucedida.
Jobs concluidos ou falhos tambem possuem TTL configuravel, de uma hora por
padrao, para limpar inclusive Jobs de tentativas falhas que o Helm nao removeu.
O ultimo fica disponivel para diagnostico ate o proximo upgrade/uninstall ou TTL.
Falhas de SQL interrompem a transacao e impedem a nova API de iniciar.

As migrations fornecidas sao reexecutaveis; ao adicionar novas migrations,
preserve essa propriedade ou implemente um historico adequado. Copie-as para
`infra/helm/mural/files/migrations/`, sem modificar a aplicacao para contornar
a migracao. O Job tem prazo e limite de tentativas configuraveis.

Liveness da API usa `/healthz`; readiness usa `/readyz`. Indisponibilidade do
banco retira a API do trafego, mas nao reinicia o processo por liveness.
Front e Postgres possuem probes proprias. Todos os containers, incluindo
Job e initContainer, possuem requests/limits configurados por `values.yaml`.

O Postgres e um StatefulSet com PVC `data-mural-postgres-0`. `PGDATA` usa um
subdiretorio do volume. `postgres.persistence.storageClass` vazio usa a
StorageClass padrao do cluster (no kind, `standard`); tamanho e recursos sao
parametrizaveis. StorageClass e outros campos imutaveis do StatefulSet nao podem
ser alterados por um upgrade comum.

## Conferir, atualizar e remover

```powershell
kubectl --context kind-mural-dev -n mural get pods,services,ingress,pvc,jobs
kubectl --context kind-mural-dev -n mural logs job/mural-migrate-1
kubectl --context kind-mural-dev -n mural exec deployment/mural-web -- wget -q -O - http://mural-api/readyz
kubectl --context kind-mural-dev -n mural delete pod mural-postgres-0
kubectl --context kind-mural-dev -n mural rollout status statefulset/mural-postgres --timeout=120s
```

Depois da recuperacao, o recado deve continuar no navegador. Para testar upgrade,
repita o comando `helm upgrade --install mural ...` com o mesmo arquivo privado
e confira o Job da nova revisao. Imagens, tags, replicas, portas da API/Services,
host, credencial e recursos sao configurados por valores, nao editando templates.

```powershell
helm uninstall mural --namespace mural --kube-context kind-mural-dev --wait
helm uninstall traefik --namespace traefik --kube-context kind-mural-dev --wait
kind delete cluster --name mural-dev
```

O uninstall remove recursos gerenciados pela release atual, mas conserva o PVC do
StatefulSet para proteger os dados. ConfigMaps de tentativas de upgrade que
falharam podem permanecer no namespace; Jobs dessas tentativas sao removidos
pelo TTL. Excluir o cluster de desenvolvimento apaga todos esses recursos e
tambem seus volumes locais; faca isso somente quando quiser descartar esses dados.