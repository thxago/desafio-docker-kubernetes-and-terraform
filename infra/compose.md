# Compose de desenvolvimento

Esta etapa usa apenas imagens oficiais para conhecer o Mural. Nao cria Dockerfiles nem substitui a entrega Helm + Terraform.

O starter em `app/` e a arquitetura em `docs/` foram obtidos sem alteracoes do repositorio `devfullcycle/desafio-docker-kubernetes-and-terraform`, commit `a7f29ae2776176259aa7e85c7d0cdec55a6215f0`.

## Executar

Pre-requisitos: Docker Desktop com engine Linux e Docker Compose v2. Execute os comandos na raiz do repositorio.

Crie `.env` uma unica vez no PowerShell, com uma senha aleatoria local. O comando nao sobrescreve um arquivo existente:

```powershell
if (Test-Path .env) { throw ".env ja existe; preserve a credencial atual." }
$bytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$password = [BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()
Get-Content .env.example |
    ForEach-Object { $_ -replace '^POSTGRES_PASSWORD=$', "POSTGRES_PASSWORD=$password" } |
    Set-Content .env -Encoding ascii
Remove-Variable password, bytes
```

`.env` e ignorado pelo Git. Nao use `docker compose config` sem `--quiet` em evidencias publicas: a configuracao expandida contem a senha. Containers de desenvolvimento recebem a credencial por ambiente; Secret sera responsabilidade da etapa Kubernetes.

O Compose monta a `DATABASE_URL` com usuario, senha e banco. Use valores alfanumericos/hexadecimais, sem caracteres reservados de URL. A senha gerada acima atende a essa restricao.

```powershell
docker compose config --quiet
docker compose up --build
```

Abra **http://localhost:8080**, confira o recado inicial e publique outro. O front carrega React/htm de `esm.sh`, portanto o navegador precisa de acesso a internet.

## Ordem e configuracao

| Servico | Imagem | Comportamento |
|---|---|---|
| `db` | `postgres:16-alpine` | Dados no volume `postgres-data`; healthcheck TCP com `pg_isready`. |
| `migrate` | `postgres:16-alpine` | Aguarda banco saudavel, executa todos os SQLs em ordem lexicografica e encerra. Cada arquivo roda em transacao; qualquer erro interrompe a sequencia. |
| `api` | `golang:1.23-alpine` | Aguarda banco e migracao bem-sucedida; executa `go run` com codigo somente leitura e caches em volumes. |
| `web` | `nginx:1.27-alpine` | Aguarda API saudavel; processa o template nginx existente com `API_UPSTREAM=api:8080`. |

O banco usa `POSTGRES_USER`, `POSTGRES_DB` e `POSTGRES_PASSWORD`. A API recebe somente `DATABASE_URL` e `PORT=8080` como configuracao da aplicacao. O nginx escuta em 8080 e encaminha `/api/` para a API sem alterar o caminho.

Somente o front e publicado no host, em loopback. Banco e API ficam na rede interna do Compose.

O healthcheck da API usa `/readyz`: banco e tabela `messages` precisam estar disponiveis. Esse check controla prontidao e dependencias, nao reinicia o container. `/healthz` apenas informa que o processo esta vivo e deve ser usado como liveness na etapa Kubernetes.

As migrations existentes criam a tabela e inserem o seed somente se ela estiver vazia. Reexecuta-las nao apaga recados; esta etapa nao implementa um historico generico de migrations.

## Verificar e encerrar

Em outro terminal:

```powershell
docker compose ps --all
docker compose logs migrate
Invoke-RestMethod http://localhost:8080/api/messages
docker compose exec api wget -q -O - http://127.0.0.1:8080/healthz
docker compose exec api wget -q -O - http://127.0.0.1:8080/readyz
```

Depois de publicar um recado, reinicie o banco sem apagar o volume:

```powershell
docker compose restart db
```

Aguarde a recuperacao do healthcheck e atualize o navegador: o recado deve permanecer. Uma indisponibilidade temporaria do banco pode deixar `/readyz` indisponivel, enquanto `/healthz` continua respondendo.

`docker compose down` encerra os containers e remove a rede, mas preserva os dados e caches. Para recomecar com os mesmos dados, reutilize `.env` e execute novamente `docker compose up --build`. Alterar a senha de `.env` nao altera a senha de um banco ja inicializado.

**Somente para descartar intencionalmente os dados deste projeto**, execute `docker compose down --volumes`. Isso remove tambem os caches Go. Nao execute esse comando em um projeto Compose compartilhado.
