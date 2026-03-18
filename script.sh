#!/usr/bin/env bash
#
#  mtld-svc-acc-lnx — Configuração remota de conta de serviço em servidores Linux
#
#  Execução (recomendado):
#    export SSH_KEY='...'
#    export SSH_KEY_PASSPHRASE='...'
#    export MATILDA_SVC_ACC_PASSWORD='...'
#    curl -sL -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/ericmelomp/mtld-svc-acc-lnx/main/script.sh?$(date +%s)" | bash
#
#  Variáveis obrigatórias:
#    SSH_KEY                    Caminho da chave .pem para conectar aos servidores
#    SSH_KEY_PASSPHRASE         Senha da chave .pem (script só funciona com export)
#    MATILDA_SVC_ACC_PASSWORD   Senha do utilizador criado nos servidores (SVC_ACC_USER)
#
#  Variáveis opcionais:
#    SVC_ACC_USER   Nome do utilizador nos alvos (default: matilda-svc-acc)
#    SERVER_LIST    Ficheiro com lista user@host (default: servers.txt ou ~/tmp/.mtld-svc-acc/servers.txt)
#
#  Acesso nos servidores: utilizador com senha (sem chaves .pem).
#
set -e

# -----------------------------------------------------------------------------
#  Execução por pipe (curl | bash): gravar script e reexecutar com stdin do
#  terminal, para não consumir o próprio código em leituras de stdin (ex.: ssh-add).
# -----------------------------------------------------------------------------
if [[ ! -t 0 ]]; then
    SCRIPT_TMP=$(mktemp 2>/dev/null || echo "/tmp/mtld-svc-acc-$$.sh")
    export _MTLD_SCRIPT_TMP="$SCRIPT_TMP"
    cat > "$SCRIPT_TMP"
    if [[ -e /dev/tty ]]; then
        exec bash "$SCRIPT_TMP" 0</dev/tty
    else
        exec bash "$SCRIPT_TMP"
    fi
fi

# -----------------------------------------------------------------------------
#  Cores (apenas se a saída for um terminal)
# -----------------------------------------------------------------------------
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
#  VARIÁVEIS DE CONFIGURAÇÃO
# =============================================================================

# --- Obrigatórias ---
SSH_KEY="${SSH_KEY:-}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"
SERVER_LIST="${SERVER_LIST:-servers.txt}"

# --- Opcionais ---
SSH_KEY_PASSPHRASE="${SSH_KEY_PASSPHRASE:-}"
SVC_ACC_USER="${SVC_ACC_USER:-matilda-svc-acc}"
MATILDA_SVC_ACC_PASSWORD="${MATILDA_SVC_ACC_PASSWORD:-}"
RESULT_FILE="${RESULT_FILE:-result.txt}"

# --- Diretório do script (ou ~/tmp/.mtld-svc-acc quando executado via curl|bash) ---
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="${HOME}/tmp/.mtld-svc-acc"
    mkdir -p "$SCRIPT_DIR"
fi
[[ "$SCRIPT_DIR" == "$HOME/tmp/.mtld-svc-acc" ]] && SERVER_LIST="${SERVER_LIST:-$SCRIPT_DIR/servers.txt}"

# =============================================================================
#  VALIDAÇÃO (ficheiros e variáveis obrigatórias)
# =============================================================================
if [[ ! -f "$SERVER_LIST" ]]; then
    echo -e "${RED}Obrigatório: ficheiro de servidores não encontrado: $SERVER_LIST${R}" >&2
    exit 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
    echo -e "${RED}Obrigatório: chave SSH não encontrada: $SSH_KEY${R}" >&2
    echo -e "${D}Defina SSH_KEY com o caminho completo (ex.: export SSH_KEY='\$HOME/.ssh/sua_chave.pem')${R}" >&2
    exit 1
fi
if [[ -z "$MATILDA_SVC_ACC_PASSWORD" ]]; then
    echo -e "${RED}Obrigatório: MATILDA_SVC_ACC_PASSWORD não definida.${R}" >&2
    echo -e "${D}Defina a senha do utilizador $SVC_ACC_USER (ex.: export MATILDA_SVC_ACC_PASSWORD='sua_senha')${R}" >&2
    exit 1
fi

mapfile -t SERVERS < <(grep -v '^[[:space:]]*#' "$SERVER_LIST" | grep -v '^[[:space:]]*$' || true)
if [[ ${#SERVERS[@]} -eq 0 ]]; then
    echo -e "${RED}Obrigatório: nenhum servidor em $SERVER_LIST (adicione um por linha)${R}" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
#  Comandos a executar em cada servidor (senha em base64 para o remoto)
# -----------------------------------------------------------------------------
MATILDA_PASS_B64=$(printf '%s' "$MATILDA_SVC_ACC_PASSWORD" | base64 -w 0 2>/dev/null || printf '%s' "$MATILDA_SVC_ACC_PASSWORD" | base64 | tr -d '\n')
SUDOERS_B64=$(printf '%s\n' "Defaults:${SVC_ACC_USER} !requiretty" "${SVC_ACC_USER} ALL=(ALL) NOPASSWD: ALL" | base64 | tr -d '\n')

CMDS=(
    "sudo useradd -m -s /bin/bash $SVC_ACC_USER 2>/dev/null || true"
    "echo \"${SVC_ACC_USER}:\$(echo $MATILDA_PASS_B64 | base64 -d)\" | sudo chpasswd"
    "echo '$SUDOERS_B64' | base64 -d | sudo tee /etc/sudoers.d/$SVC_ACC_USER"
    "sudo chmod 440 /etc/sudoers.d/$SVC_ACC_USER"
    "sudo grep -q '^[^#]*Defaults.*requiretty' /etc/sudoers && sudo cp /etc/sudoers /etc/sudoers.bak.requiretty && sudo sed -i 's/^\([^#]*Defaults.*requiretty\)/# \\1/' /etc/sudoers && sudo visudo -c || true"
    "sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config"
    "sudo find /etc/ssh/sshd_config.d/ -type f -name '*.conf' -exec sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' {} +"
    "sudo sshd -t && (sudo systemctl restart ssh || sudo systemctl restart sshd)"
    "(command -v apt-get >/dev/null 2>&1 && sudo apt-get update -qq && sudo apt-get install -y bc net-tools) || (command -v yum >/dev/null 2>&1 && sudo yum install -y bc net-tools) || true"
    "sudo su - $SVC_ACC_USER -c 'sudo whoami'"
    "(sudo systemctl enable sshd 2>/dev/null && sudo systemctl start sshd 2>/dev/null) || (sudo systemctl enable ssh 2>/dev/null && sudo systemctl start ssh 2>/dev/null); (sudo systemctl is-active sshd 2>/dev/null || sudo systemctl is-active ssh 2>/dev/null)"
)

if [[ ${#CMDS[@]} -eq 0 ]]; then
    echo -e "${RED}Defina pelo menos um comando no array CMDS.${R}" >&2
    exit 1
fi
CMD="$(printf '%s && ' "${CMDS[@]}" | sed 's/ && $//')"

# --- Verificação "já configurado" (evita reconfigurar) ---
#CHECK_ALREADY_CMD='sudo id '"$SVC_ACC_USER"' >/dev/null 2>&1 && sudo grep -q NOPASSWD /etc/sudoers.d/'"$SVC_ACC_USER"' 2>/dev/null'

# -----------------------------------------------------------------------------
#  SSH: opções e carregamento da chave no agente (apenas via export)
# -----------------------------------------------------------------------------
SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

AGENT_STARTED=
if [[ -n "$SSH_KEY" && -f "$SSH_KEY" ]]; then
    eval "$(ssh-agent -s)"
    AGENT_STARTED=1
    if [[ -n "$SSH_KEY_PASSPHRASE" ]]; then
        # Askpass: senha dentro do script (ssh-add pode rodar com env limpo)
        TMP_ASKPASS=$(mktemp 2>/dev/null || echo /tmp/ssh_askpass_$$)
        PP_ESC=$(printf '%s' "$SSH_KEY_PASSPHRASE" | sed "s/'/'\\\\''/g")
        printf '#!/bin/sh\nprintf "%%s" '\''%s'\''\n' "$PP_ESC" > "$TMP_ASKPASS"
        chmod 700 "$TMP_ASKPASS"
        export SSH_ASKPASS="$TMP_ASKPASS"
        export SSH_ASKPASS_REQUIRE=force
        unset DISPLAY
        export DISPLAY=dummy:0
        ADD_OK=
        if command -v timeout >/dev/null 2>&1; then
            timeout 15 bash -c 'exec 0</dev/null; ssh-add "$SSH_KEY"' 2>/dev/null && ADD_OK=1
        else
            ( exec 0</dev/null; ssh-add "$SSH_KEY" ) 2>/dev/null && ADD_OK=1
        fi
        if [[ -z "$ADD_OK" ]]; then
            rm -f "$TMP_ASKPASS"
            unset SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY
            echo -e "${RED}Não foi possível adicionar a chave com SSH_KEY_PASSPHRASE.${R}" >&2
            echo -e "${D}Verifique a senha e o caminho da chave. O script só funciona com export (sem pedir senha no terminal).${R}" >&2
            exit 1
        fi
        rm -f "$TMP_ASKPASS"
        unset SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY
    else
        echo -e "${RED}Obrigatório: defina SSH_KEY_PASSPHRASE (a chave .pem tem senha).${R}" >&2
        echo -e "${D}Ex.: export SSH_KEY_PASSPHRASE='sua_senha_da_chave'${R}" >&2
        echo -e "${D}O script só funciona com variáveis em export; não solicita senha no terminal.${R}" >&2
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
#  Redirecionar saída para terminal e para result.txt (sem códigos ANSI)
# -----------------------------------------------------------------------------
exec 3>&1
exec 1> >(tee >(sed $'s/\033\\[[0-9;]*m//g' > "$RESULT_FILE") >&3)
exec 2>&1

# --- Banner ---
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

# --- Caixa de cabeçalho ---
RUN_TIME=$(date '+%Y-%m-%d %H:%M:%S')
BOX_W=72
L1="  Configuração remota: utilizador $SVC_ACC_USER (conta de serviço)"
L2="  ${#SERVERS[@]} servidor(es) · ${#CMDS[@]} passos · ${RUN_TIME}"
L1_len=${#L1}
L2_len=${#L2}
L1_pad=$((BOX_W - L1_len))
L2_pad=$((BOX_W - L2_len))
[[ $L1_pad -lt 0 ]] && L1_pad=0
[[ $L2_pad -lt 0 ]] && L2_pad=0
printf -v PAD1 '%*s' "$L1_pad" ''
printf -v PAD2 '%*s' "$L2_pad" ''
EQ_LINE=""
for ((i=0;i<BOX_W;i++)); do EQ_LINE="${EQ_LINE}="; done

echo ""
echo -e "${CYAN}${B}+${EQ_LINE}+${R}"
echo -e "${CYAN}${B}|${R}${B}${L1}${R}${PAD1}${CYAN}${B}|${R}"
echo -e "${CYAN}${B}|${R}${B}${L2}${R}${PAD2}${CYAN}${B}|${R}"
echo -e "${CYAN}${B}+${EQ_LINE}+${R}"
echo ""
echo -e "${B}O que será feito em cada servidor:${R}"
echo -e "  ${D}1.${R} Criar utilizador $SVC_ACC_USER (bash, home) com senha"
echo -e "  ${D}2.${R} Configurar sudo sem senha (NOPASSWD) em /etc/sudoers.d/$SVC_ACC_USER"
echo -e "  ${D}3.${R} Comentar Defaults requiretty em /etc/sudoers (se existir)"
echo -e "  ${D}4.${R} Ativar PasswordAuthentication no sshd (principal + sshd_config.d), validar (sshd -t) e reiniciar SSH"
echo -e "  ${D}5.${R} Instalar dependências: bc, net-tools (yum ou apt)"
echo -e "  ${D}6.${R} Testar sudo sem senha (sudo whoami → root)"
echo -e "  ${D}7.${R} Garantir que o serviço SSH está ativo (sshd ou ssh)"
echo -e "  ${D}→ Se o servidor já tiver $SVC_ACC_USER e sudo NOPASSWD, será omitido.${R}"
echo ""
echo -e "  ${D}Chave SSH (conexão do executor):${R} $SSH_KEY"
echo -e "  ${D}Resultado guardado em:${R} $RESULT_FILE"
echo ""

# =============================================================================
#  Execução por servidor
# =============================================================================
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

    if ssh "${SSH_OPTS[@]}" "$server" "$CHECK_ALREADY_CMD" 2>/dev/null; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        SKIP_SERVERS+=("$server")
        echo -e "  ${BLUE}${B}⊙ Skipped${R}  $server"
        echo -e "  ${D}→ Utilizador $SVC_ACC_USER e sudo NOPASSWD já existem; nada a fazer.${R}"
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
        echo -e "  ${D}→ Utilizador $SVC_ACC_USER criado (acesso com senha), sudo sem senha ativo, dependências e SSH verificados.${R}"
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

# =============================================================================
#  Resumo final
# =============================================================================
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
echo -e "  ${D}Em cada servidor com sucesso: utilizador $SVC_ACC_USER (login por senha), sudo NOPASSWD, bc/net-tools e SSH ativo.${R}"
echo -e "${CYAN}${B}═══════════════════════════════════════════════════════════════════════════${R}"
echo ""
[[ -n "${_MTLD_SCRIPT_TMP:-}" && -f "${_MTLD_SCRIPT_TMP}" ]] && rm -f "$_MTLD_SCRIPT_TMP"
