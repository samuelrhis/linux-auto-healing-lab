# Arquitetura do Projeto

## Visão geral

O Linux Auto-Healing Lab foi criado para simular um cenário de infraestrutura Linux em que uma aplicação gera logs continuamente e pode causar crescimento excessivo de uso em disco.

O objetivo do projeto é detectar esse comportamento, coletar evidências do incidente e executar uma remediação controlada, mantendo o ambiente seguro e observável.

## Ambiente

O laboratório roda em uma máquina virtual Debian utilizando KVM/QEMU.

A escolha de uma VM isolada permite testar cenários de saturação de disco sem comprometer o sistema operacional principal.

Para aumentar a segurança do laboratório, foi criado um filesystem dedicado de aproximadamente 1 GB.

```text
Host Linux
   |
   v
KVM/QEMU
   |
   v
VM Debian
   |
   v
/var/lib/disk-lab.img
   |
   v
/dev/loop0
   |
   v
/mnt/disk-lab
```

O filesystem utiliza ext4 e é montado automaticamente através do `/etc/fstab`.

## Aplicação simulada

O projeto possui um gerador de logs responsável por simular uma aplicação com alto volume de escrita.

Arquivo principal:

```text
simulator/generate-load.sh
```

O simulador grava continuamente em:

```text
/mnt/disk-lab/app-logs/application.log
```

As mensagens incluem eventos simulados como:

```text
[INFO]
[WARN]
[ERROR]
```

Isso permite testar crescimento de disco e análise de incidentes em um ambiente controlado.

## Disk Guardian

O componente principal do projeto é:

```text
guardian/disk-guardian.sh
```

Suas responsabilidades incluem:

- monitorar o percentual de uso do filesystem;
- medir a taxa de crescimento do log;
- identificar crescimento anormal;
- coletar evidências;
- identificar o processo responsável pela escrita;
- executar remediação quando necessário;
- validar o resultado da remediação;
- registrar os eventos da própria execução.

## Thresholds

A primeira versão utiliza três níveis:

```text
70% -> WARNING
80% -> REMEDIATION
85% -> CRITICAL
```

O monitoramento do crescimento do log é independente desses thresholds.

Por exemplo, mesmo que o filesystem esteja em 40%, um crescimento muito rápido pode ser classificado como anomalia.

## Detecção de crescimento anormal

O Guardian mede o tamanho do log em dois momentos.

Exemplo:

```text
T0
application.log = 100 MB

10 segundos depois

T1
application.log = 150 MB
```

Resultado:

```text
Growth = 50 MB / 10s
```

Quando o crescimento ultrapassa o threshold configurado, uma anomalia é registrada.

Essa abordagem permite detectar comportamento anormal antes que o disco chegue a um nível crítico.

## Coleta de evidências

Antes de executar uma remediação, o Guardian coleta contexto sobre o incidente.

São coletadas informações como:

```text
Filesystem usage
Log size
Log growth rate
ERROR count
WARN count
Recent relevant events
PID
Process user
Process command
```

A análise de conteúdo é limitada às linhas mais recentes do log para evitar processamento excessivo de arquivos muito grandes.

## Identificação do processo

O projeto utiliza `lsof` para descobrir qual processo está utilizando o arquivo de log.

A partir do PID encontrado, o comando completo é obtido utilizando `ps`.

Exemplo:

```text
PID: 9296
User: samuelrhis
Command: /bin/bash ./simulator/generate-load.sh
```

Isso fornece contexto adicional para investigação do incidente.

## Estratégia de rotação

Durante o desenvolvimento foi inicialmente testado o `copytruncate`.

Essa abordagem apresentou uma limitação importante.

Em um cenário em que o filesystem estava em aproximadamente 86%, o log possuía cerca de 775 MB e havia apenas aproximadamente 131 MB livres.

O `copytruncate` tentou copiar o arquivo antes de truncá-lo e falhou por falta de espaço.

O comportamento foi utilizado como aprendizado para alterar a estratégia.

A configuração atual utiliza:

```text
rename
create
compress
```

Fluxo:

```text
application.log
      |
      v
rename
      |
      v
application.log-TIMESTAMP
      |
      +------> gzip
      |
      v
novo application.log
```

Com isso, o arquivo não precisa ser duplicado antes da rotação.

## Remediação

Quando o filesystem atinge o nível de remediação ou crítico:

```text
Detecção
   |
   v
Coleta de evidências
   |
   v
logrotate
   |
   v
Rotação
   |
   v
Compressão
   |
   v
Nova medição do filesystem
```

O Guardian verifica novamente o uso do disco após a execução.

Se o uso permanecer crítico, o incidente é marcado como necessitando investigação manual.

A automação não continua removendo arquivos indefinidamente.

## Proteção contra execução concorrente

O projeto utiliza `flock`.

Isso evita que múltiplas instâncias do Guardian sejam executadas ao mesmo tempo.

Exemplo de cenário evitado:

```text
Execução A
   |
   v
Remediação em andamento

Execução B
   |
   v
Lock ocupado
   |
   v
Execução encerrada
```

O lock é mantido em:

```text
/run/disk-guardian.lock
```

## systemd

O Guardian é integrado ao systemd através de dois componentes:

```text
disk-guardian.service
disk-guardian.timer
```

O service utiliza:

```text
Type=oneshot
```

Isso significa que o processo inicia, executa a rotina e encerra.

O timer é responsável por iniciar o serviço periodicamente.

Fluxo:

```text
disk-guardian.timer
        |
        v
disk-guardian.service
        |
        v
disk-guardian.sh
```

Na configuração atual do laboratório, o timer executa a cada minuto.

## Logging

O Guardian mantém um log próprio em:

```text
/var/log/disk-guardian/disk-guardian.log
```

Os eventos utilizam níveis como:

```text
INFO
WARNING
ANOMALY
REMEDIATION
CRITICAL
SUCCESS
ERROR
RESOLVED
```

Além do arquivo próprio, as execuções iniciadas pelo systemd também podem ser consultadas através do journal:

```bash
journalctl -u disk-guardian.service
```

## CI

O repositório utiliza GitHub Actions para validar alterações.

Fluxo atual:

```text
Push / Pull Request
        |
        v
   GitHub Actions
      /       \
     v         v
ShellCheck   bash -n
```

O ShellCheck realiza análise estática dos scripts Shell.

O comando:

```bash
bash -n
```

verifica a sintaxe dos scripts sem executá-los.

A pipeline já identificou e ajudou a corrigir problemas durante o desenvolvimento do laboratório.

## Estrutura atual

```text
linux-auto-healing-lab/
|
├── .github/
│   └── workflows/
│       └── ci.yml
|
├── docs/
│   └── architecture.md
|
├── guardian/
│   ├── disk-guardian.sh
│   └── guardian.conf.example
|
├── logrotate/
│   └── disk-guardian-lab
|
├── simulator/
│   └── generate-load.sh
|
├── systemd/
│   ├── disk-guardian.service
│   └── disk-guardian.timer
|
├── README.md
└── LICENSE
```

## Evolução planejada

A arquitetura foi criada para permitir evolução incremental.

Próximas etapas planejadas:

```text
v1
Linux + Bash + logrotate + systemd + CI

        |
        v

v1.1
Node Exporter + Prometheus + Grafana

        |
        v

v1.2
Alertmanager + Loki

        |
        v

v2
Docker

        |
        v

v3
Ansible / Infraestrutura automatizada

        |
        v

v4
Kubernetes + Helm
```

## Princípios utilizados

O projeto procura seguir alguns princípios importantes:

- automação segura;
- menor privilégio possível;
- coleta de evidências antes da remediação;
- validação após a execução;
- proteção contra concorrência;
- observabilidade;
- evolução incremental;
- infraestrutura reproduzível;
- CI desde as primeiras versões.
