# Linux Auto-Healing Lab

Laboratório DevOps/SRE focado em monitoramento de disco Linux, detecção de crescimento anormal de logs, análise preditiva de risco e remediação automatizada.

## Objetivo do projeto

Este projeto simula um cenário comum em ambientes Linux:

- uma aplicação gera logs continuamente;
- o crescimento dos logs é monitorado;
- comportamentos anormais são detectados antes que o filesystem entre em estado crítico;
- a taxa de crescimento é utilizada para estimar o tempo restante até o esgotamento do filesystem;
- evidências do incidente são coletadas automaticamente;
- uma rotação controlada dos logs é executada quando necessário;
- todo o processo é automatizado com systemd.

O laboratório foi criado para estudar, de forma segura e reproduzível, práticas de automação, prevenção de incidentes, troubleshooting e conceitos de SRE.

## Arquitetura atual

```text
Aplicação simulada
       |
       v
/mnt/disk-lab/app-logs/application.log
       |
       v
   Disk Guardian
       |
       +--> Uso do filesystem
       |
       +--> Taxa de crescimento do log
       |
       +--> Estimativa de tempo até esgotamento
       |
       +--> Coleta de evidências
       |
       +--> Identificação do processo
       |
       v
    logrotate
       |
       v
Rotação + Compressão
       |
       v
Validação pós-remediação
```

Automação:

```text
systemd timer
     |
     v
disk-guardian.service
     |
     v
disk-guardian.sh
```

CI:

```text
Push / Pull Request
        |
        v
  GitHub Actions
     /       \
ShellCheck   Bash syntax
```

## Ambiente de laboratório

O projeto atualmente roda em uma máquina virtual Debian utilizando KVM/QEMU.

Para simular consumo de disco com segurança, sem comprometer o filesystem principal da VM, foi criado um filesystem ext4 dedicado de aproximadamente 1 GB utilizando uma imagem de disco.

```text
/var/lib/disk-lab.img
        |
        v
    /dev/loop0
        |
        v
 /mnt/disk-lab
```

Esse filesystem é montado automaticamente através do `/etc/fstab`.

Com isso, é possível simular crescimento de logs, saturação de disco e remediação sem colocar o sistema operacional principal da VM em risco.

## Disk Guardian

O Guardian trabalha com três níveis de uso do filesystem:

```text
70% -> WARNING
80% -> REMEDIATION
85% -> CRITICAL
```

Além dos thresholds fixos, o crescimento do log é monitorado de forma independente.

A lógica atual prioriza a proteção do filesystem:

```text
Uso >= 85%
    -> CRITICAL
    -> remediação imediata

Uso >= 80%
    -> REMEDIATION
    -> remediação imediata

Uso < 80%
    -> mede crescimento por 10 segundos
    -> reavalia o uso do filesystem
    -> estima o tempo até esgotamento
```

Quando o filesystem já está em nível de remediação ou crítico, o Guardian não espera a janela de 10 segundos antes de agir.

## Detecção de crescimento anormal

Quando o filesystem ainda está abaixo do nível de remediação, o Guardian mede o tamanho do log em dois momentos.

Exemplo:

```text
T0
application.log = 600 MB

10 segundos depois

T1
application.log = 647 MB
```

Resultado:

```text
Growth = 47 MB / 10s
```

Quando o crescimento ultrapassa o limite configurado, uma anomalia é registrada.

```text
[ANOMALY] Abnormal log growth detected: 47 MB in 10s
```

## Remediação preditiva

Além dos thresholds tradicionais, o Guardian calcula uma estimativa simples do tempo restante até o filesystem ficar sem espaço.

A estimativa utiliza:

```text
espaço livre / taxa atual de crescimento
```

Exemplo observado no laboratório:

```text
Disk usage: 71%
Growth: 47 MB in 10s

[PREDICTION] Estimated time to filesystem exhaustion: ~46s
[PREEMPTIVE] Fast log growth may exhaust the filesystem within 60s
```

Quando a estimativa indica risco de esgotamento em até 60 segundos, o Guardian pode antecipar a rotação dos logs, mesmo que o filesystem ainda não tenha atingido 80%.

Em um dos testes:

```text
Análise iniciada: 71%
Remediação iniciada: 77%
Após remediação: 4%
```

Fluxo:

```text
Crescimento anormal
        |
        v
Calcula taxa de crescimento
        |
        v
Calcula ETA até esgotamento
        |
        v
ETA <= 60s?
   |         |
  sim       não
   |         |
   v         v
PREEMPTIVE  apenas alerta
   |
   v
logrotate
   |
   v
validação
```

Essa abordagem reduz a dependência exclusiva de thresholds fixos e permite reagir a um crescimento acelerado antes que o filesystem fique próximo de 100%.

## Coleta de evidências

Quando uma anomalia é identificada, o Guardian coleta informações úteis para investigação:

- tamanho do log;
- taxa de crescimento;
- estimativa de tempo até esgotamento, quando disponível;
- quantidade de mensagens ERROR;
- quantidade de mensagens WARN;
- últimas linhas relevantes;
- PID do processo utilizando o log;
- usuário responsável pelo processo;
- comando completo do processo.

Exemplo:

```text
Process using log:

PID: 5972
User: samuelrhis
Command: /bin/bash ./simulator/generate-load.sh
```

Para evitar processamento desnecessário em arquivos muito grandes, a análise de conteúdo é limitada às últimas 50.000 linhas.

As últimas mensagens relevantes também são obtidas somente dessa janela recente, evitando a leitura completa de um log com centenas de megabytes.

## Remediação de logs

O projeto utiliza o `logrotate` para realizar a remediação.

A escolha foi feita para evitar exclusões diretas e utilizar uma ferramenta nativa do Linux para gerenciamento de logs.

Quando uma remediação é necessária:

1. o Guardian identifica o estado do filesystem;
2. coleta evidências;
3. aciona o `logrotate`;
4. o log atual é rotacionado;
5. um novo arquivo de log é criado;
6. o arquivo anterior é comprimido;
7. o uso do filesystem é verificado novamente.

Exemplo:

```text
[ACTION] Triggering preemptive log rotation
[SUCCESS] Log rotation completed
[INFO] Disk usage changed from 77% to 4%
[RESOLVED] Disk usage returned to a safe level
```

Caso o uso permaneça crítico após a remediação, o Guardian registra a necessidade de investigação manual.

## Estratégia de rotação

Durante o desenvolvimento foi testado inicialmente o `copytruncate`.

Em um cenário com pouco espaço livre, essa abordagem falhou porque o arquivo precisava ser copiado antes de ser truncado.

A configuração foi alterada para uma estratégia baseada em:

```text
rename
create
compress
```

Com isso, o arquivo original não precisa ser duplicado antes da rotação.

### Limitação conhecida do laboratório

Durante cargas muito agressivas do simulador, o processo pode continuar escrevendo enquanto o arquivo rotacionado começa a ser comprimido.

Nessa situação, o `gzip` pode registrar:

```text
gzip: stdin: file size changed while zipping
```

Nos testes atuais a rotação ainda concluiu e recuperou espaço, porém esse comportamento está documentado como uma limitação conhecida do workload simulado.

Em uma aplicação real, a estratégia de rotação deve considerar a forma como o processo mantém e reabre seus file descriptors.

## Proteção contra execução simultânea

O Guardian utiliza `flock` para impedir que duas instâncias executem a rotina ao mesmo tempo.

O lock é mantido em:

```text
/run/disk-guardian.lock
```

Isso evita que múltiplas remediações atuem simultaneamente sobre os mesmos arquivos.

## Automação com systemd

O Guardian é executado como um serviço `oneshot` do systemd.

O timer atual utiliza:

```ini
OnBootSec=15s
OnUnitInactiveSec=15s
AccuracySec=1s
```

Com `OnUnitInactiveSec=15s`, uma nova execução é agendada aproximadamente 15 segundos após a conclusão da execução anterior.

Isso evita que uma rotina mais longa gere disparos consecutivos imediatamente após terminar.

Comandos úteis:

```bash
systemctl status disk-guardian.timer
systemctl list-timers --all | grep disk-guardian
journalctl -u disk-guardian.service
sudo journalctl -fu disk-guardian.service
```

## Logs do próprio Guardian

O Disk Guardian registra suas próprias ações em:

```text
/var/log/disk-guardian/disk-guardian.log
```

Os principais níveis registrados atualmente incluem:

```text
INFO
WARNING
ANOMALY
PREDICTION
PREEMPTIVE
REMEDIATION
CRITICAL
ACTION
SUCCESS
ERROR
ALERT
ACTION_REQUIRED
RESOLVED
```

Exemplo:

```text
[ANOMALY] Abnormal log growth detected: 47 MB in 10s
[PREDICTION] Estimated time to filesystem exhaustion: ~46s
[PREEMPTIVE] Fast log growth may exhaust the filesystem within 60s
[ACTION] Triggering preemptive log rotation
[SUCCESS] Log rotation completed
[RESOLVED] Disk usage returned to a safe level
```

## Pipeline CI

O projeto possui uma pipeline no GitHub Actions que executa validações a cada push e pull request para a branch `main`.

Atualmente são executadas:

- análise estática com ShellCheck;
- validação de sintaxe Bash com `bash -n`.

Isso ajuda a detectar problemas no código antes de considerar uma alteração válida.

## Estrutura do repositório

```text
linux-auto-healing-lab/
├── .github/
│   └── workflows/
│       └── ci.yml
├── docs/
│   └── architecture.md
├── guardian/
│   ├── disk-guardian.sh
│   └── guardian.conf.example
├── logrotate/
│   └── disk-guardian-lab
├── simulator/
│   └── generate-load.sh
├── systemd/
│   ├── disk-guardian.service
│   └── disk-guardian.timer
├── README.md
└── LICENSE
```

## Tecnologias utilizadas

- Linux / Debian
- Bash
- systemd
- logrotate
- flock
- lsof
- Git
- GitHub
- GitHub Actions
- ShellCheck
- KVM/QEMU

## Roadmap

Próximas evoluções planejadas:

```text
v1
Linux + Bash + logrotate + systemd + CI
Detecção de anomalias + remediação preditiva

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

## Status

Versão atual: **v1**

O núcleo de monitoramento, detecção de anomalias, previsão de risco, remediação automatizada, execução via systemd e validação CI está funcional.

A próxima etapa será adicionar observabilidade com Node Exporter, Prometheus e Grafana.
