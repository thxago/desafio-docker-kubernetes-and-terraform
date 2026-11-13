# Bonus: HPA, carga e automacao

Os bonus sao opcionais e nao substituem o Terraform maestro. A aplicacao original
permanece inalterada. O fluxo obrigatorio continua com replicas fixas por padrao.

## Habilitar autoscaling

Use os pre-requisitos e a credencial local do README. Na raiz, prepare sua
configuracao privada antes do primeiro apply:

```powershell
Copy-Item infra\terraform\bonus.tfvars.example infra\terraform\bonus.auto.tfvars
```

O arquivo `.auto.tfvars` e ignorado pelo Git. Ele habilita `enable_autoscaling`
e configura min/max de replicas e alvo CPU por `mural_values`. Se voce ja ajustou
`mural_values` em outro tfvars, combine essas opcoes: uma variavel de mapa e
substituida integralmente quando fornecida novamente, nao mesclada pelo Terraform.
Configure tambem as portas privadas conforme o README, se necessario.

Com `enable_autoscaling = true`, o mesmo Terraform:

- Baixa e carrega a imagem oficial de metrics-server no kind.
- Instala o chart metrics-server 3.13.0, imagem v0.8.0, com requests/limits.
- Habilita o HPA `autoscaling/v2` da API, com CPU por utilizacao dos requests.

O alvo padrao e **60% de 100m CPU por pod**, com **2 a 5 replicas**. As replicas
da API deixam de ser declaradas no Deployment quando o HPA esta ativo, evitando
que Helm/Terraform sobrescrevam a escala. Com o bonus desligado, as replicas
fixas existentes e a ausencia de HPA/metrics-server sao preservadas.

O metrics-server usa `--kubelet-insecure-tls` para os certificados locais do
kubelet no kind. Essa concessao e restrita ao laboratorio; nao leve essa
configuracao a clusters de producao. Downloads de imagens/charts continuam
validando TLS normalmente. Os valores TLS da API agregada seguem o chart oficial.

## Atalhos PowerShell

Os comandos abaixo partem da raiz; o script resolve seus diretorios internamente.
PowerShell 7, Terraform, kind e Docker precisam estar no PATH.

```powershell
pwsh -NoProfile -File .\infra\mural.ps1 up
pwsh -NoProfile -File .\infra\mural.ps1 plan
pwsh -NoProfile -File .\infra\mural.ps1 down
```

`up` executa init, verificacao de formatacao, validate e apply. `plan` mostra
as mudancas; `down` executa destroy. As confirmacoes do Terraform permanecem
interativas; use `-AutoApprove` somente quando quiser aprovar explicitamente
o apply/destroy sem prompt.

O script le `.env` quando presente, respeita variaveis `TF_VAR_*` ja definidas
e restaura o ambiente ao terminar. Tambem aceita credenciais fornecidas por
tfvars privado; nao gera, imprime ou versiona segredos. Nao cria clusters nem
aplica manifests fora do Terraform.

O script nao copia tfvars automaticamente: edite sua configuracao privada antes
de executa-lo. `up` sozinho, sem o arquivo de bonus, mantem o fluxo obrigatorio.

## Teste de carga

Instale **k6** e kubectl no PATH; a validacao usou k6 2.4.0. Suba o ambiente
com autoscaling habilitado e execute:

```powershell
pwsh -NoProfile -File .\infra\mural.ps1 load
# Ou ajuste o teste:
pwsh -NoProfile -File .\infra\load-test.ps1 -DurationSeconds 180 -Vus 40
```

`infra/load/api.js` executa GET `/api/messages` com usuarios virtuais concorrentes,
sem gravar dados nem alterar a aplicacao. O script obtem o URL e kubeconfig dos
outputs Terraform, aguarda metricas CPU e o minimo de pods Ready e roda k6 com
prazo limitado. Somente processos iniciados pelo proprio teste sao encerrados.

Os checks exigem HTTP 200 e resposta JSON em array, com taxa de erro menor que
1% e mais de 99% de checks aprovados. O runner amostra HPA/Deployment a cada
5 segundos e exige aumento de **replicas Ready**, nao apenas desejadas. Se o
HPA ja estiver no maximo, aguarde a carga anterior terminar e a escala diminuir.

Relatorios k6, logs e amostras HPA ficam em `infra/.evidence/`, ignorado pelo Git.
Cada execucao usa nomes unicos; o JSON de HPA referencia o summary k6. Os relatorios
nao contem credenciais ou kubeconfig. Um teste sem aumento de replicas ou com
falha nos thresholds encerra com erro, preservando evidencias para diagnostico.

Em cluster local a escala e ilustrativa: os pods disputam o mesmo node e o
Postgres pode virar gargalo. CPU maior que o alvo nao garante aumento continuo
de throughput, principalmente quando o HPA atinge maxReplicas.

## Idempotencia e limpeza

Depois do teste, mantenha os mesmos tfvars e execute `up` novamente. O esperado
e **0 added, 0 changed, 0 destroyed**, sem resetar a escala do Deployment.
O HPA pode reduzir replicas naturalmente depois da carga; isso nao e drift
provocado pelo Terraform.

Execute `down` com os mesmos arquivos privados: metrics-server, HPA e todos
os demais recursos do cluster sao removidos junto com o ambiente. Imagens
oficiais e caches compartilhados continuam preservados, como no fluxo obrigatorio.
Para uma nova instalacao sem bonus, remova apenas o seu `bonus.auto.tfvars`
apos encerrar o ambiente ou configure `enable_autoscaling = false`.

Os testes de regressao podem ser executados sem cluster; o teste do chart
exige Helm no PATH, enquanto o teste da automacao simula o Terraform:

```powershell
pwsh -NoProfile -File .\infra\tests\hpa.ps1
pwsh -NoProfile -File .\infra\tests\mural.ps1
```

Eles cobrem HPA desativado, valores parametrizados, ownership de replicas,
politicas invalidas, propagacao de falhas e restauracao das variaveis de
credenciais, inclusive quando elas nao existiam antes do comando.

## Evidencias

Validacao real no cluster kind `mural-bonus`, linux/amd64, com acesso por
`http://mural.localtest.me:18080` e os valores padrao de HPA:

| Verificacao | Resultado |
|---|---|
| Primeiro `up -AutoApprove` | 9 recursos criados, incluindo metrics-server. |
| Carga k6 | 40 usuarios virtuais, durante 180 segundos. |
| Escala observada | **2 para 5 replicas Ready** da API; metricas CPU disponiveis. |
| Requisicoes | 129.038, aproximadamente 716,77 por segundo. |
| Qualidade | 0% de falhas HTTP; 258.076 checks aprovados, nenhum reprovado; k6 exit 0. |
| Latencia p95 | 107,45 ms. |
| Segundo `up -AutoApprove` | **0 added, 0 changed, 0 destroyed**. |
| `plan` e plano detalhado | Sem mudancas; `-detailed-exitcode` retornou 0. |
| `down -AutoApprove` | **9 recursos removidos**; state vazio. |
| Limpeza exclusiva | Cluster, tags proprias e kubeconfig removidos; imagens compartilhadas preservadas. |
| Bonus desativado | Plano limpo com 8 recursos, sem metrics-server; chart preserva replicas fixas. |

Os atalhos preservaram o ambiente de credenciais apos sucesso e falha.
As amostras reais estao em
`infra/.evidence/55cb33cd6f30478ca860c5902e04450e-hpa.json`; o campo
`summaryFile` aponta para o relatorio k6 correspondente. Esses arquivos ficam
locais e ignorados; os resultados acima sao a evidencia versionavel.
Os tfvars, state e backups temporarios da validacao foram removidos somente
apos confirmar o destroy e o state vazio. A credencial local `.env` foi preservada.