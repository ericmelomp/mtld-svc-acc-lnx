#!/usr/bin/env bash

set -e

if [[ -t 1 ]]; then
    R="\033[0m"
    B="\033[1m"
    D="\033[2m"
    RED="\033[31m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    BLUE="\033[34m"
    CYAN="\033[36m"
    MAGENTA="\033[35m"
else
    R=""; B=""; D=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; MAGENTA=""
fi

# =============================================================================
# VARIÁVEIS OBRIGATÓRIAS (preencher antes de executar)
# =============================================================================
SSH_KEY="${SSH_KEY:-}"           # Caminho da chave privada para conectar aos servidores
SSH_KEY="${SSH_KEY/#\~/$HOME}"                         # Expande ~ para $HOME (Git Bash / Windows)
SERVER_LIST="${SERVER_LIST:-servers.txt}"              # Ficheiro com a lista de servidores (um por linha: user@host)

# =============================================================================
# VARIÁVEIS OPCIONAIS (valores por defeito; alterar só se precisar)
# =============================================================================
SSH_KEY_PASSPHRASE="${SSH_KEY_PASSPHRASE:-}"          # Senha da chave SSH; vazio = pede ao executar
RESULT_FILE="${RESULT_FILE:-result.txt}"               # Ficheiro onde guardar o resultado da execução
MATILDA_KEY_BASE="${MATILDA_KEY_BASE:-}"              # Caminho base da chave matilda_srv (vazio = pasta do script)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$MATILDA_KEY_BASE" ]]; then
    MATILDA_KEY_BASE="$SCRIPT_DIR/matilda_srv_key"
fi

if [[ ! -f "$SERVER_LIST" ]]; then
    echo -e "${RED}Obrigatório: ficheiro de servidores não encontrado: $SERVER_LIST${R}" >&2
    exit 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
    echo -e "${RED}Obrigatório: chave SSH não encontrada: $SSH_KEY${R}" >&2
    echo -e "${D}Defina SSH_KEY com o caminho completo (ex.: export SSH_KEY=\"\$HOME/.ssh/sua_chave.pem\")${R}" >&2
    exit 1
fi

mapfile -t SERVERS < <(grep -v '^[[:space:]]*#' "$SERVER_LIST" | grep -v '^[[:space:]]*$' || true)
if [[ ${#SERVERS[@]} -eq 0 ]]; then
    echo -e "${RED}Obrigatório: nenhum servidor em $SERVER_LIST (adicione um por linha)${R}" >&2
    exit 1
fi

if [[ ! -f "$MATILDA_KEY_BASE" ]]; then
    ssh-keygen -t ed25519 -f "$MATILDA_KEY_BASE" -C "matilda-service-account" -N ""
fi
MATILDA_PUBKEY_FILE="${MATILDA_KEY_BASE}.pub"
if [[ ! -f "$MATILDA_PUBKEY_FILE" ]]; then
    echo -e "${RED}Ficheiro de chave pública não encontrado: $MATILDA_PUBKEY_FILE${R}" >&2
    exit 1
fi
MATILDA_PUBKEY_B64=$(base64 < "$MATILDA_PUBKEY_FILE" | tr -d '\n')
SUDOERS_B64=$(printf '%s\n' 'Defaults:matilda-srv !requiretty' 'matilda-srv ALL=(ALL) NOPASSWD: ALL' | base64 | tr -d '\n')

CMDS=(
    "sudo useradd -m -s /bin/bash matilda-srv 2>/dev/null || true"
    "sudo passwd -l matilda-srv"
    "sudo mkdir -p /home/matilda-srv/.ssh"
    "sudo chmod 700 /home/matilda-srv/.ssh"
    "sudo chown -R matilda-srv:matilda-srv /home/matilda-srv/.ssh"
    "echo '$MATILDA_PUBKEY_B64' | base64 -d | sudo tee /home/matilda-srv/.ssh/authorized_keys"
    "sudo chmod 600 /home/matilda-srv/.ssh/authorized_keys"
    "sudo chown matilda-srv:matilda-srv /home/matilda-srv/.ssh/authorized_keys"
    "echo '$SUDOERS_B64' | base64 -d | sudo tee /etc/sudoers.d/matilda-srv"
    "sudo chmod 440 /etc/sudoers.d/matilda-srv"
    "sudo grep -q '^[^#]*Defaults.*requiretty' /etc/sudoers && sudo cp /etc/sudoers /etc/sudoers.bak.requiretty && sudo sed -i 's/^\([^#]*Defaults.*requiretty\)/# \\1/' /etc/sudoers && sudo visudo -c || true"
    "(command -v apt-get >/dev/null 2>&1 && sudo apt-get update -qq && sudo apt-get install -y bc net-tools) || (command -v yum >/dev/null 2>&1 && sudo yum install -y bc net-tools) || true"
    "sudo su - matilda-srv -c 'sudo -l' && sudo su - matilda-srv -c 'sudo whoami'"
    "(sudo netstat -anlp 2>/dev/null; sudo ss -tunlp 2>/dev/null; sudo dmidecode -s system-manufacturer 2>/dev/null; sudo crontab -l 2>/dev/null; sudo route -n 2>/dev/null; sudo readlink -f /proc/1/exe 2>/dev/null; sudo ifconfig -a 2>/dev/null || sudo ip a 2>/dev/null); true"
    "(sudo systemctl enable sshd 2>/dev/null && sudo systemctl start sshd 2>/dev/null) || (sudo systemctl enable ssh 2>/dev/null && sudo systemctl start ssh 2>/dev/null); (sudo systemctl is-active sshd 2>/dev/null || sudo systemctl is-active ssh 2>/dev/null)"
)

if [[ ${#CMDS[@]} -eq 0 ]]; then
    echo -e "${RED}Defina pelo menos um comando no array CMDS.${R}" >&2
    exit 1
fi
CMD="$(printf '%s && ' "${CMDS[@]}" | sed 's/ && $//')"

# Comando para verificar se a máquina já tem matilda-srv configurado (evita reconfigurar)
# Redirecionamento POSIX (>/dev/null 2>&1); &> não existe em /bin/sh (dash)
CHECK_ALREADY_CMD='sudo id matilda-srv >/dev/null 2>&1 && sudo test -s /home/matilda-srv/.ssh/authorized_keys && sudo grep -q NOPASSWD /etc/sudoers.d/matilda-srv 2>/dev/null'

SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

AGENT_STARTED=
if [[ -n "$SSH_KEY" && -f "$SSH_KEY" ]]; then
    eval "$(ssh-agent -s)"
    AGENT_STARTED=1
    if [[ -n "$SSH_KEY_PASSPHRASE" ]]; then
        # ssh-add pode ser invocado com ambiente limpo (sem SSH_KEY_PASSPHRASE), por isso
        # gravamos a senha dentro do script askpass (escapada) em vez de usar a variável.
        TMP_ASKPASS=$(mktemp 2>/dev/null || echo /tmp/ssh_askpass_$$)
        # Escapar para uso dentro de single-quoted sh: ' -> '\''
        PP_ESC=$(printf '%s' "$SSH_KEY_PASSPHRASE" | sed "s/'/'\\\\''/g")
        printf '#!/bin/sh\nprintf "%%s" '\''%s'\''\n' "$PP_ESC" > "$TMP_ASKPASS"
        chmod 700 "$TMP_ASKPASS"
        export SSH_ASKPASS="$TMP_ASKPASS"
        export SSH_ASKPASS_REQUIRE=force
        unset DISPLAY
        # Forçar uso do askpass: DISPLAY vazio faz alguns ssh-add ignorarem askpass;
        # usar valor dummy faz ssh-add usar askpass sem tentar abrir X.
        export DISPLAY=dummy:0
        # timeout deve envolver o ssh-add (máx. 15s) para não travar
        ADD_OK=
        if command -v timeout >/dev/null 2>&1; then
            timeout 15 bash -c 'exec 0</dev/null; ssh-add "$SSH_KEY"' 2>/dev/null && ADD_OK=1
        else
            ( exec 0</dev/null; ssh-add "$SSH_KEY" ) 2>/dev/null && ADD_OK=1
        fi
        if [[ -z "$ADD_OK" ]]; then
            # Fallback: pseudo-TTY para poder introduzir a senha manualmente
            echo -e "${YELLOW}ssh-add por variável falhou. A introduzir senha manualmente (copie/cole se tiver):${R}" >&2
            if command -v script >/dev/null 2>&1; then
                script -q -c "ssh-add \"$SSH_KEY\"" /dev/null 2>/dev/null || ssh-add "$SSH_KEY" || true
            else
                ssh-add "$SSH_KEY" || true
            fi
        fi
        rm -f "$TMP_ASKPASS"
        unset SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY
    else
        if [[ ! -t 0 ]]; then
            echo -e "${RED}Sem TTY e SSH_KEY_PASSPHRASE não definida. Defina a variável ou execute com terminal interativo.${R}" >&2
            exit 1
        fi
        echo -e "${YELLOW}Introduza a senha da chave (se tiver):${R}"
        ssh-add "$SSH_KEY"
    fi
fi

exec 3>&1
exec 1> >(tee >(sed $'s/\033\\[[0-9;]*m//g' > "$RESULT_FILE") >&3)
exec 2>&1

echo -e "${MAGENTA}"
echo " .d8888b.                                 .d8888b.                    888          "
echo "d88P  Y88b                               d88P  Y88b                   888          "
echo "888    888                               Y88b.                        888          "
echo "888         .d88b.  888d888 .d88b.        \"Y888b.    .d8888b  8888b.  888  .d88b.  "
echo "888        d88\"\"88b 888P\"  d8P  Y8b          \"Y88b. d88P\"        \"88b 888 d8P  Y8b "
echo "888    888 888  888 888    88888888            \"888 888      .d888888 888 88888888 "
echo "Y88b  d88P Y88..88P 888    Y8b.          Y88b  d88P Y88b.    888  888 888 Y8b.     "
echo " \"Y8888P\"   \"Y88P\"  888     \"Y8888        \"Y8888P\"   \"Y8888P \"Y888888 888  \"Y8888  "
echo ""
echo -e "${R}"

RUN_TIME=$(date '+%Y-%m-%d %H:%M:%S')
BOX_W=72
L1="  Configuração remota: utilizador matilda-srv (conta de serviço)"
L2="  ${#SERVERS[@]} servidor(es) · ${#CMDS[@]} passos · ${RUN_TIME}"
# Padding até BOX_W para alinhar o canto direito
L1_len=${#L1}
L2_len=${#L2}
L1_pad=$((BOX_W - L1_len))
L2_pad=$((BOX_W - L2_len))
[[ $L1_pad -lt 0 ]] && L1_pad=0
[[ $L2_pad -lt 0 ]] && L2_pad=0
printf -v PAD1 '%*s' "$L1_pad" ''
printf -v PAD2 '%*s' "$L2_pad" ''
# Linha de = sem depender de seq
EQ_LINE=""
for ((i=0;i<BOX_W;i++)); do EQ_LINE="${EQ_LINE}="; done

echo ""
echo -e "${CYAN}${B}+${EQ_LINE}+${R}"
echo -e "${CYAN}${B}|${R}${B}${L1}${R}${PAD1}${CYAN}${B}|${R}"
echo -e "${CYAN}${B}|${R}${B}${L2}${R}${PAD2}${CYAN}${B}|${R}"
echo -e "${CYAN}${B}+${EQ_LINE}+${R}"
echo ""
echo -e "${B}O que será feito em cada servidor:${R}"
echo -e "  ${D}1.${R} Criar utilizador matilda-srv (bash, home) e bloquear login por senha"
echo -e "  ${D}2.${R} Criar ~/.ssh, implantar chave pública e configurar authorized_keys"
echo -e "  ${D}3.${R} Configurar sudo sem senha (NOPASSWD) em /etc/sudoers.d/matilda-srv"
echo -e "  ${D}4.${R} Comentar Defaults requiretty em /etc/sudoers (se existir)"
echo -e "  ${D}5.${R} Instalar dependências: bc, net-tools (yum ou apt)"
echo -e "  ${D}6.${R} Testar sudo sem senha (sudo whoami → root)"
echo -e "  ${D}7.${R} Validar comandos: netstat, ss, dmidecode, crontab, route"
echo -e "  ${D}8.${R} Garantir que o serviço SSH está ativo (sshd ou ssh)"
echo -e "  ${D}→ Se o servidor já tiver matilda-srv com chave e sudo NOPASSWD, será omitido.${R}"
echo ""
echo -e "  ${D}Chave SSH (conexão):${R} $SSH_KEY"
echo -e "  ${D}Chave matilda-srv (deploy):${R} $MATILDA_PUBKEY_FILE"
echo -e "  ${D}Resultado guardado em:${R} $RESULT_FILE"
echo ""

OK_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL=${#SERVERS[@]}
OK_SERVERS=()
FAIL_SERVERS=()
SKIP_SERVERS=()

for idx in "${!SERVERS[@]}"; do
    server="${SERVERS[idx]}"
    current=$((idx + 1))

    echo -e "${MAGENTA}${B}┌─────────────────────────────────────────────────────────────────────────┐${R}"
    echo -e "${MAGENTA}${B}│${R}  ${B}Servidor ${current}/${TOTAL}${R}  ${CYAN}${server}${R}"
    echo -e "${MAGENTA}${B}└─────────────────────────────────────────────────────────────────────────┘${R}"

    # Verificar se já está configurado
    if ssh "${SSH_OPTS[@]}" "$server" "$CHECK_ALREADY_CMD" 2>/dev/null; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        SKIP_SERVERS+=("$server")
        echo -e "  ${BLUE}${B}⊙ Skipped${R}  $server"
        echo -e "  ${D}→ Utilizador matilda-srv, chave e sudo NOPASSWD já existem; nada a fazer.${R}"
        echo ""
        continue
    fi

    echo -e "  ${D}Saída dos comandos no servidor:${R}"
    echo ""

    if ssh "${SSH_OPTS[@]}" "$server" "$CMD"; then
        OK_COUNT=$((OK_COUNT + 1))
        OK_SERVERS+=("$server")
        echo ""
        echo -e "  ${GREEN}${B}✓ Concluído com sucesso${R}  $server"
        echo -e "  ${D}→ Utilizador matilda-srv criado, chave implantada, sudo sem senha ativo, dependências e SSH verificados.${R}"
    else
        ssh_exit=$?
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_SERVERS+=("$server")
        echo ""
        echo -e "  ${RED}${B}✗ Falha${R}  $server (código de saída: $ssh_exit)"
        echo -e "  ${D}→ Verifique a saída acima e a conectividade/permissões no servidor.${R}" >&2
    fi
    echo ""
done

[[ -n "$AGENT_STARTED" && -n "$SSH_AGENT_PID" ]] && kill "$SSH_AGENT_PID" 2>/dev/null || true

echo -e "${CYAN}${B}═══════════════════════════════════════════════════════════════════════════${R}"
echo -e "  ${B}Resumo da execução${R}"
echo -e "${CYAN}${B}═══════════════════════════════════════════════════════════════════════════${R}"
echo ""
echo -e "  ${GREEN}${B}Sucesso:${R} ${OK_COUNT}  ${BLUE}${B}Skipped:${R} ${SKIP_COUNT}  ${RED}${B}Falha:${R} ${FAIL_COUNT}  ${B}Total:${R} ${TOTAL}"
echo ""
if [[ ${#OK_SERVERS[@]} -gt 0 ]]; then
    echo -e "  ${GREEN}Servidores configurados (agora):${R}"
    for s in "${OK_SERVERS[@]}"; do echo -e "    ${GREEN}✓${R} $s"; done
    echo ""
fi
if [[ ${#SKIP_SERVERS[@]} -gt 0 ]]; then
    echo -e "  ${BLUE}Servidores skipped:${R}"
    for s in "${SKIP_SERVERS[@]}"; do echo -e "    ${BLUE}⊙${R} $s"; done
    echo ""
fi
if [[ ${#FAIL_SERVERS[@]} -gt 0 ]]; then
    echo -e "  ${RED}Servidores com falha:${R}"
    for s in "${FAIL_SERVERS[@]}"; do echo -e "    ${RED}✗${R} $s"; done
    echo ""
fi
echo -e "  ${D}Em cada servidor com sucesso: utilizador matilda-srv, chave SSH, sudo NOPASSWD, bc/net-tools e SSH ativo.${R}"
echo -e "${CYAN}${B}═══════════════════════════════════════════════════════════════════════════${R}"
echo ""
