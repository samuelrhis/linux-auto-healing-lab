# Linux Auto-Healing Lab

Laboratório DevOps/SRE focado em monitoramento de disco Linux, detecção de crescimento anormal de logs e remediação automatizada.

## Objetivo do projeto

Este projeto simula um cenário comum em ambientes Linux:

- uma aplicação gera logs continuamente;
- o crescimento dos logs é monitorado;
- comportamentos anormais são detectados antes que o filesystem entre em estado crítico;
- evidências do incidente são coletadas automaticamente;
- uma rotação controlada dos logs é executada quando necessário;
- todo o processo é automatizado com systemd.

O laboratório foi criado para estudar, de forma segura e reproduzível, práticas de automação, prevenção de incidentes e conceitos de SRE.

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
       +--> Thresholds de uso do disco
       |
       +--> Detecção de crescimento anormal
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

Para simular o consumo de disco com segurança, sem comprometer o filesystem principal da VM, foi criado um filesystem ext4 dedicado de aproximadamente 1 GB utilizando uma imagem de disco.

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

Com isso, é possível simular crescimento de logs, saturação de disco e remediação sem colocar o sistema operacional da VM em risco.

## Disk Guardian

O Guardian trabalha atualmente com três níveis de uso do filesystem:

- Warning: 70%
- Remediation: 80%
- Critical: 85%

Além disso, o crescimento do log da aplicação é monitorado de forma independente do percentual de uso do disco.

Exemplo:

```text
Disk usage: 46%

[ANOMALY] Abnormal log growth detected.
Growth: 50 MB in 10s
```

Isso permite identificar um comportamento anormal antes que o filesystem chegue a um estado crítico.

## Coleta de evidências

Quando uma anomalia é identificada, o Guardian coleta informações úteis para investigação:

- tamanho do log;
- taxa de crescimento;
- quantidade de mensagens ERROR;
- quantidade de mensagens WARN;
- últimas linhas relevantes;
- PID do processo utilizando o log;
- usuário responsável pelo processo;
- comando completo do processo.

Exemplo:

```text
Process using log:

PID: 9296
User: samuelrhis
Command: /bin/bash ./simulator/generate-load.sh
```

Para evitar processamento desnecessário em arquivos muito grandes, apenas uma janela recente do log é analisada.

## Remediação de logs

O projeto utiliza o `logrotate` para realizar a remediação.

A escolha foi feita para evitar exclusões diretas e utilizar uma ferramenta nativa e consolidada do Linux para gerenciamento de logs.

Quando o nível de remediação é atingido:

1. o Guardian coleta evidências;
2. o `logrotate` é acionado;
3. o log atual é rotacionado;
4. um novo arquivo de log é criado;
5. o arquivo anterior é comprimido;
6. o uso do filesystem é verificado novamente.

Caso o uso permaneça crítico após a remediação, o Guardian registra a necessidade de investigação manual.

## Proteção contra execução simultânea

O Guardian utiliza `flock` para evitar que duas instâncias sejam executadas ao mesmo tempo.

Isso reduz o risco de duas rotinas de remediação atuarem simultaneamente sobre os mesmos arquivos.

## Automação com systemd

O Guardian é executado como um serviço `oneshot` do systemd.

Um `systemd timer` executa o serviço automaticamente a cada minuto no ambiente atual do laboratório.

Comandos úteis:

```bash
systemctl status disk-guardian.timer
systemctl list-timers --all | grep disk-guardian
journalctl -u disk-guardian.service
```

## Logs do próprio Guardian

O Disk Guardian registra suas próprias ações em:

```text
/var/log/disk-guardian/disk-guardian.log
```

Exemplo:

```text
2026-09-15 11:00:20 [INFO] Disk Guardian execution started
2026-09-15 11:00:20 [INFO] Filesystem usage is 14%
2026-09-15 11:00:30 [OK] Disk usage and log growth are normal
2026-09-15 11:00:30 [INFO] Disk Guardian execution finished
```

## Pipeline CI

O projeto possui uma pipeline no GitHub Actions que executa validações a cada push e pull request para a branch `main`.

Atualmente são executadas:

- validação com ShellCheck;
- validação de sintaxe Bash com `bash -n`.

Isso ajuda a detectar problemas no código antes de considerar uma alteração válida.

## Estrutura do repositório

```text
.
├── docs/
├── guardian/
│   └── disk-guardian.sh
├── logrotate/
│   └── disk-guardian-lab
├── simulator/
│   └── generate-load.sh
├── systemd/
│   ├── disk-guardian.service
│   └── disk-guardian.timer
└── .github/
    └── workflows/
        └── ci.yml
```

## Tecnologias utilizadas

- Linux
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

- métricas com Prometheus;
- integração com Node Exporter;
- dashboards no Grafana;
- alertas com Alertmanager;
- centralização de logs com Loki;
- simulação de workloads com Docker;
- provisionamento automatizado;
- Ansible;
- Kubernetes;
- Helm.

## Status

Versão atual: **v1**

O núcleo de monitoramento, detecção de anomalias, remediação, automação e CI já está funcional.
