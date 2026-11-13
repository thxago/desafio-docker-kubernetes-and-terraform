# Terraform maestro

O fluxo final parte de `infra/terraform/`: um unico `terraform apply` constroi
as imagens, cria o kind, carrega as imagens, cria o namespace `mural` e o Secret,
instala Traefik e o chart do Mural, aguarda migrations e verifica o Ingress.
Nao e necessario executar `kind create`, `kind load` ou `kubectl apply`.

## Pre-requisitos

- Windows com PowerShell 7 (`pwsh`) e Docker Desktop usando containers Linux.
- Terraform >= 1.9 e < 2.0; validacao realizada com 1.13.5.
- kind 0.30.0 no PATH. kubectl e util para diagnostico, mas nao e exigido pelo apply.
- Acesso a internet para baixar providers, imagens oficiais e o chart Traefik.
- Pelo menos 5 GiB livres antes do provisionamento; reserve mais para um Docker
  sem caches. O script interrompe a construcao se o espaco estiver abaixo disso.
- Portas HTTP/HTTPS livres (80/443 por padrao). Nao reutilize o nome de um
  cluster existente ou o mesmo state para gerenciar ambientes diferentes.

Todos os comandos de infraestrutura precisam usar o mesmo usuario/contexto Docker.
O Terraform usa os providers `tehcyx/kind` 0.13.0, `hashicorp/helm` 3.3.0 e
`hashicorp/kubernetes` 3.5.0. O lockfile versionado fixa tambem os checksums.

## Configurar e executar

Se ainda nao houver `.env`, gere-o conforme `infra/compose.md`. Na raiz:

```powershell
$config = ConvertFrom-StringData (Get-Content .env -Raw)
$env:TF_VAR_postgres_password = $config.POSTGRES_PASSWORD
$env:TF_VAR_postgres_username = $config.POSTGRES_USER
$env:TF_VAR_postgres_database = $config.POSTGRES_DB
Remove-Variable config

Set-Location infra\terraform
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt -check
terraform validate
terraform apply
```

Nao sobrescreva um `terraform.tfvars` ja configurado. O exemplo nao contem senha.
`terraform.tfvars`, arquivos privados `.tfvars.json`, plans, state e kubeconfig
sao ignorados pelo Git. `TF_VAR_postgres_password` evita colocar a senha no
historico de comandos; remova a variavel do ambiente apos encerrar o trabalho.
Se usar arquivo privado, mantenha-o fora do versionamento.

O segredo e criado pelo provider Kubernetes como `mural-database`, com chaves
`password` e `database-url`. O Helm recebe apenas `existingSecret`, nao a senha.
Caracteres reservados na URL sao escapados automaticamente. **Sensitive nao e
criptografia**: o state e seus backups contem a senha e a chave privada do cluster.
Proteja o acesso local e, para uso compartilhado, configure um backend com
criptografia, controle de acesso e locking. Nunca publique state ou kubeconfig.

Ao concluir, o output `url` aponta para **http://mural.localtest.me**.
O dominio resolve para loopback; o navegador precisa tambem de internet para
os modulos React/htm do front. HTTP e o acesso usado nesta etapa; mapear 443
nao configura um certificado TLS para a aplicacao.

## Entradas e imagens

`terraform.tfvars.example` mostra nome do cluster, host, portas e configuracao
do banco. `mural_values` permite ajustar replicas, resources, persistencia e
portas da API/Services, conforme `infra/helm/mural/values.yaml`. Terraform impoe
os nomes/tags das imagens construidas, o Secret e o roteamento do Ingress.

As imagens da aplicacao usam repositorios `<cluster>-api` e `<cluster>-web`,
com tags `tf-<hash-do-conteudo>`. Hashes incluem fontes, Dockerfiles e exclusoes
de contexto. Modificacoes reais provocam rebuild/carregamento; o segundo
apply sem modificacoes nao reexecuta os comandos. Cada imagem recebe um label
de propriedade; o script recusa substituir/remover tags de outros projetos.

`platform` e `linux/amd64` por padrao. Ajuste para `linux/arm64` somente se o
node kind e o host forem compativeis. Imagens do Postgres, node e Traefik sao
parametrizaveis; mantenha `traefik_chart_version` e `traefik_image_tag` compativeis.

O carregamento exporta um arquivo temporario de plataforma unica, importa-o
via `kind load image-archive` e remove-o em `finally`. Isso evita os blobs
multiarch ausentes do Docker Desktop e downloads dentro do node, inclusive
em redes com certificados corporativos. Nenhuma verificacao TLS e desabilitada.

O cluster usa label `ingress-ready=true`, NodePorts 30080/30443 e mapeamento
para as portas locais configuradas. O kubeconfig fica dedicado em
`infra/terraform/.runtime/<cluster>.kubeconfig`, sem usar o contexto atual
como fonte de credenciais dos providers.

## Idempotencia e limpeza

Execute novamente, com os mesmos arquivos e entradas:

```powershell
terraform apply
```

O resultado esperado e `0 added, 0 changed, 0 destroyed`. Para verificar
automaticamente, `terraform plan -detailed-exitcode` retorna 0 quando nao ha
mudancas e 2 quando ha um plano de alteracao. Nao use timestamps como gatilhos.

Para inspecionar recursos, na raiz:

```powershell
kubectl --kubeconfig infra\terraform\.runtime\mural-terraform.kubeconfig -n mural get pods,pvc,ingress,jobs
```

Para desfazer, com a mesma credencial e configuracao usadas no apply:

```powershell
terraform destroy
Remove-Item Env:\TF_VAR_postgres_password
```

A ordem remove o Mural antes de Traefik/namespace/Secret e remove o cluster
antes das tags de imagem construidas pelo fluxo. Excluir o cluster elimina
tambem os PVCs locais. O kubeconfig dedicado e removido quando nao existem
nodes desse cluster; rebuilds de imagens nao apagam o kubeconfig de um
cluster ainda ativo.

As imagens oficiais e caches de Docker/BuildKit/providers nao sao recursos
exclusivos desta instalacao: podem ser compartilhados com Compose e outros
projetos. O destroy nao faz prune, nao remove essas dependencias compartilhadas
e nao apaga o state automaticamente. Ele deixa o state sem recursos gerenciados;
state/backup continuam privados. Nunca use reset/limpeza global do Docker
para desfazer uma instalacao.

Trocar nome/node/port-mappings substitui o kind (o provider nao altera clusters
existentes) e descarta os dados locais; examine o plano antes de aprovar.
Mudar senha/usuario/banco em um Postgres ja inicializado nao migra suas
credenciais: reutilize os valores ou faca uma rotacao controlada no banco.
Nao remova manualmente imagens/cluster gerenciados pelo state; se isso ocorrer,
reconcile o plano antes de continuar.

Se um apply falhar, corrija a causa e repita-o com o mesmo state, ou use
`terraform destroy`. Nao crie outro cluster manualmente para contornar o erro.
As migrations e suas falhas/recuperacao seguem o comportamento descrito em
`infra/helm.md`.

## Evidencia do ciclo

Em 2026-11-13, com Terraform 1.13.5, Docker 28.4.0 e cluster isolado
`mural-eb9a4cdb`, o primeiro apply criou 8 recursos e disponibilizou
o Mural via Traefik. O navegador exibiu o seed e publicou um recado com HTTP 201.
O segundo apply retornou **0 added, 0 changed, 0 destroyed**; o plan com
`-detailed-exitcode` retornou 0 e os IDs do node, pods e PVC permaneceram iguais.
O destroy removeu os 8 recursos, as imagens exclusivas e o kubeconfig dedicado,
preservando as imagens compartilhadas e o kubeconfig padrao.