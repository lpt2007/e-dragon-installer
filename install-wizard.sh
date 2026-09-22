#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════
# install-wizard.sh — Čarovnik za namestitev e-dragon-llm-node
#
# Uporaba:
#   sudo ./install-wizard.sh --list            # Prikaže vse korake
#   sudo ./install-wizard.sh --step N          # Izvede korak N
#   sudo ./install-wizard.sh --step N --dry-run  # Predogled brez sprememb
#   sudo ./install-wizard.sh --resume          # Nadaljuje zadnji nezaključen korak
#
# Stanje: /root/e-dragon-install/ (ali $E_DRAGON_INSTALL_DIR)
# Vse datoteke imajo predpono <PREFIX> (npr. PODJETJE-20260101-P001state.env)
# ════════════════════════════════════════════════════════════════

set -Eeuo pipefail

# ── Konstante ──────────────────────────────────────────────────
readonly DATE_FORMAT="%Y%m%d"
readonly DEFAULT_INSTALL_DIR="/root/e-dragon-install"
readonly WIZARD_VERSION="0.1.0"
readonly SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_HASH="$(sha256sum "$SCRIPT_PATH" 2>/dev/null | cut -d' ' -f1 || echo 'unknown')"

# Ime zasebnega repozitorija in GHCR organizacija (spremenljivo)
readonly DEFAULT_GITHUB_REPO="lpt2007/e-dragon-llm-node"
readonly DEFAULT_GHCR_ORG="lpt2007"

# ── Barve ──────────────────────────────────────────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

# ── Globalne spremenljivke ─────────────────────────────────────
INSTALL_DIR="${E_DRAGON_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
PREFIX=""
DRY_RUN=false
CURRENT_STEP=""
STEP_STATUS="PASS"
STEP_NOTES=""
WIZARD_HASH=""

# ════════════════════════════════════════════════════════════════
#  BARVNI IZPISI
# ════════════════════════════════════════════════════════════════

info()    { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[FAIL]${RESET} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}"; }

# ════════════════════════════════════════════════════════════════
#  UPORABA IN STIKALA
# ════════════════════════════════════════════════════════════════

usage() {
    cat <<'EOF'
Uporaba: install-wizard.sh [STIKALO]
(Opomba: zaženi z sudo; E_DRAGON_INSTALL_DIR lahko podajaš z export pred sudo)

Stikala:
  --list              Prikaže vse korake
  --step N            Izvede korak N (0–9)
  --step N --dry-run  Predogled koraka N brez sprememb
  --resume            Nadaljuje zadnji nezaključen korak

Okoljske spremenljivke:
  E_DRAGON_INSTALL_DIR  Pot do imenika stanja (privzeto /root/e-dragon-install/)

Primeri:
  sudo ./install-wizard.sh --list
  sudo ./install-wizard.sh --step 0
  export E_DRAGON_INSTALL_DIR=/tmp/test && sudo -E ./install-wizard.sh --step 1
EOF
}

# ════════════════════════════════════════════════════════════════
#  SEZNAM KORAKOV
# ════════════════════════════════════════════════════════════════

list_steps() {
    echo -e "${BOLD}Koraki čarovnika:${RESET}"
    printf "  %-3s  %s\n" "0" "Identifikacija stranke (ime, pogodba, predpona)"
    printf "  %-3s  %s\n" "1" "Preverba gostitelja (Proxmox, GPU, IOMMU, shramba)"
    printf "  %-3s  %s\n" "2" "Passthrough priprava (vfio, GPU dodelitev) — še ni implementirano"
    printf "  %-3s  %s\n" "3" "Deploy key (GitHub read-only SSH) — še ni implementirano"
    printf "  %-3s  %s\n" "4" "GHCR token (classic PAT, read:packages) — še ni implementirano"
    printf "  %-3s  %s\n" "5" "Ustvarjanje VM (ubuntu-vm.sh) — še ni implementirano"
    printf "  %-3s  %s\n" "6" "GPU v VM (qm set --hostpci0) — še ni implementirano"
    printf "  %-3s  %s\n" "7" "IP in prva prijava (DHCP, ssh-keygen -R) — še ni implementirano"
    printf "  %-3s  %s\n" "8" "Namestitev v VM (bootstrap.sh + setup.sh) — še ni implementirano"
    printf "  %-3s  %s\n" "9" "Zaključek (preverbe, poročilo) — še ni implementirano"
}

# ════════════════════════════════════════════════════════════════
#  IMENIK STANJA
# ════════════════════════════════════════════════════════════════

init_state_dir() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[dry-run] Stanje ne bo shranjeno."
        return 0
    fi
    if [[ ! -d "$INSTALL_DIR" ]]; then
        mkdir -p "$INSTALL_DIR"
        chmod 700 "$INSTALL_DIR"
        info "Ustvarjen imenik stanja: $INSTALL_DIR"
    fi
}

# load_state: naloži PREFIX in ostalo iz obstoječega *state.env
load_state() {
    if [[ -n "${PREFIX:-}" ]]; then
        info "Stanje že naloženo: PREFIX=${PREFIX}"
        return 0
    fi
    local state_file
    state_file=$(find "$INSTALL_DIR" -maxdepth 1 -name '*state.env' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2 || true)
    if [[ -n "$state_file" ]] && [[ -f "$state_file" ]]; then
        PREFIX=$(grep '^PREFIX=' "$state_file" | head -1 | cut -d'=' -f2- | tr -d '"')
        info "Stanje naloženo: ${state_file} (PREFIX=${PREFIX})"
        return 0
    fi
    warn "Ni obstoječega stanja v ${INSTALL_DIR}/ — najprej izvedi korak 0."
    return 1
}

# ════════════════════════════════════════════════════════════════
#  POMOŽNE FUNKCIJE
# ════════════════════════════════════════════════════════════════

# confirm: privzeto NE (uporabnik mora tipkati 'y')
confirm() {
    local prompt="$1"
    local answer
    echo -ne "${BOLD}${prompt} [y/N]: ${RESET}"
    read -r answer
    case "$answer" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# backup_file: kopija z datumsko pripono pred spreminjanjem
backup_file() {
    local filepath="$1"
    if [[ -f "$filepath" ]]; then
        local backup_name="${filepath}.$(date '+%Y%m%d_%H%M%S').bak"
        cp -p "$filepath" "$backup_name"
        info "Backup: $filepath → $backup_name"
    fi
}

# read_secret: vnesi skrivnost z read -rs, ne shrani v dnevnik
read_secret() {
    local prompt="$1"
    local varname="$2"
    local secret
    echo -ne "${BOLD}${prompt}${RESET} "
    read -rs secret
    echo  # novi vrstic za terminal
    # Preveri dolžino če je podan minimalni prag
    local min_len="${3:-0}"
    if [[ "$min_len" -gt 0 ]]; then
        local actual_len
        actual_len=$(printf '%s' "$secret" | wc -c)
        if [[ "$actual_len" -lt "$min_len" ]]; then
            warn "Vhod je prekratka (${actual_len} znakov, pričakovano ≥${min_len})"
            return 1
        fi
    fi
    eval "$varname=\$secret"
}

# cmd_check: preveri ali ukaz obstaja
cmd_check() {
    command -v "$1" &>/dev/null
}

# ════════════════════════════════════════════════════════════════
#  POROČILO KORAKA
# ════════════════════════════════════════════════════════════════

save_step_report() {
    local step_num="$1"
    local step_name="$2"
    local status="$3"
    local notes="$4"

    local status_color
    case "$status" in
        PASS) status_color="$GREEN" ;;
        WARN) status_color="$YELLOW" ;;
        FAIL) status_color="$RED" ;;
        *)    status_color="$RESET" ;;
    esac

    # Izhod na zaslon
    echo ""
    echo -e "${BOLD}── POROČILO KORAKA ${step_num} ──${RESET}"
    echo -e "  Korak:       ${step_name}"
    echo -e "  Status:      ${status_color}${BOLD}${status}${RESET}"
    echo -e "  Čas:         $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo -e "  Hash čarovnika: ${WIZARD_HASH}"
    if [[ -n "$notes" ]]; then
        echo -e "  Podrobnosti:"
        echo "$notes" | while IFS= read -r line; do
            echo -e "    $line"
        done
    fi
    echo ""

    # Shrani v datoteko (le če ni dry-run)
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[dry-run] Poročilo ni shranjeno."
        return 0
    fi

    if [[ -n "$PREFIX" ]]; then
        local report_file="${INSTALL_DIR}/${PREFIX}step-${step_num}-report.txt"
        {
            echo "Korak: ${step_name}"
            echo "Status: ${status}"
            echo "Cas: $(date '+%Y-%m-%d %H:%M:%S %Z')"
            echo "Hash_carovnika: ${WIZARD_HASH}"
            if [[ -n "$notes" ]]; then
                echo "Podrobnosti:"
                echo "$notes"
            fi
        } > "$report_file"
        info "Poročilo shranjeno: $report_file"
    fi
}

# ════════════════════════════════════════════════════════════════
#  KORAK 0: Identifikacija stranke
# ════════════════════════════════════════════════════════════════

normalize_company_name() {
    local name="$1"
    # Nadomesti slovenske šumnike PRED case-conversion (oba primerka: majhne in velike)
    name=$(echo "$name" | sed \
        -e 's/[čć]/c/g' -e 's/[ČĆ]/C/g' \
        -e 's/š/s/g'   -e 's/Š/S/g' \
        -e 's/ž/z/g'   -e 's/Ž/Z/g' \
        -e 's/đ/d/g'   -e 's/Đ/D/g')
    # Velike črke (samo ASCII, ker so šumniki že odstranjeni)
    name=$(echo "$name" | tr '[:lower:]' '[:upper:]')
    # Vse ne-alfanumerično v _
    name="${name//[^A-Z0-9]/_}"
    # Brez podvojenih _
    while [[ "$name" == "__"* ]]; do name="${name#__}"; done
    name="${name//__/_}"
    # Brez robnih _
    name="${name##_}"
    name="${name%_}"
    echo "$name"
}

validate_date() {
    local d="$1"
    # Preveri format YYYYMMDD in ali je veljaven datum
    if [[ "$d" =~ ^[0-9]{8}$ ]] && date -d "${d:0:4}-${d:4:2}-${d:6:2}" &>/dev/null; then
        return 0
    fi
    return 1
}

validate_contract_number() {
    local num="$1"
    if [[ "$num" =~ ^[A-Z0-9_]+$ ]]; then
        return 0
    fi
    return 1
}

step_0() {
    header "Korak 0: Identifikacija stranke"

    local company_name contract_date contract_num prefix

    # Ime podjetja
    local raw_name
    while true; do
        read -r -p "Ime podjetja: " raw_name
        if [[ -z "$raw_name" ]]; then
            error "Ime podjetja ne sme biti prazno."
            continue
        fi
        company_name=$(normalize_company_name "$raw_name")
        if [[ -z "$company_name" ]]; then
            error "Po normalizaciji ostane prazno. Poskusi z drugim imenom."
            continue
        fi
        break
    done

    # Datum pogodbe (privzeto danes)
    local default_date
    default_date=$(date +"$DATE_FORMAT")
    read -r -p "Datum sklenitve pogodbe (YYYYMMDD) [${default_date}]: " contract_date
    contract_date="${contract_date:-$default_date}"

    while ! validate_date "$contract_date"; do
        error "Neveljaven datum '$contract_date'. Pričakovan format YYYYMMDD."
        read -r -p "Poskusi znova [${default_date}]: " contract_date
        contract_date="${contract_date:-$default_date}"
    done

    # Številka pogodbe
    local raw_contract
    while true; do
        read -r -p "Številka pogodbe (samo A-Z, 0-9, _): " raw_contract
        if [[ -z "$raw_contract" ]]; then
            error "Številka pogodbe ne sme biti prazna."
            continue
        fi
        contract_num=$(echo "$raw_contract" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9_]//g')
        if ! validate_contract_number "$contract_num"; then
            error "Neveljavna številka pogodbe: samo A-Z, 0-9 in _ dovoljeni."
            continue
        fi
        break
    done

    # Sestavi predpono
    prefix="${company_name}-${contract_date}-${contract_num}_"

    # Predogled
    echo ""
    echo -e "${BOLD}Predogled:${RESET}"
    echo -e "  Ime podjetja:        ${raw_name}"
    echo -e "  Normalizirano:       ${company_name}"
    echo -e "  Datum pogodbe:       ${contract_date}"
    echo -e "  Številka pogodbe:    ${contract_num}"
    echo -e "  Predpona:            ${BOLD}${prefix}${RESET}"
    echo -e "  Imenik stanja:       ${INSTALL_DIR}/"
    echo -e "  Primer datoteke:     ${INSTALL_DIR}/${prefix}state.env"
    echo ""

    if ! confirm "Ali so podatki pravilni?"; then
        info "Korak 0 prekinit. Podatki niso shranjeni."
        STEP_STATUS="FAIL"
        STEP_NOTES="Uporabnik ni potrdil podatkov."
        save_step_report 0 "Identifikacija stranke" "$STEP_STATUS" "$STEP_NOTES"
        exit 0
    fi

    # Shrani
    PREFIX="$prefix"
    WIZARD_HASH="$SCRIPT_HASH"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[dry-run] Stanje ne bo shranjeno. PREFIX=${PREFIX}"
    else
        init_state_dir
        local state_file="${INSTALL_DIR}/${PREFIX}state.env"
        backup_file "$state_file"
        {
            echo "# Ustvarjeno: $(date '+%Y-%m-%d %H:%M:%S %Z')"
            echo "# Hash čarovnika: ${WIZARD_HASH}"
            echo "PREFIX=\"${PREFIX}\""
            echo "COMPANY_NAME=\"${raw_name}\""
            echo "COMPANY_SLUG=\"${company_name}\""
            echo "CONTRACT_DATE=\"${contract_date}\""
            echo "CONTRACT_NUM=\"${contract_num}\""
            echo "INSTALL_DIR=\"${INSTALL_DIR}\""
            echo "LAST_COMPLETED_STEP=0"
        } > "$state_file"
        chmod 600 "$state_file"
        info "Stanje shranjeno: $state_file"
    fi

    STEP_STATUS="PASS"
    STEP_NOTES="Podjetje: ${raw_name} | Predpona: ${prefix}"
    save_step_report 0 "Identifikacija stranke" "$STEP_STATUS" "$STEP_NOTES"
}

# ════════════════════════════════════════════════════════════════
#  KORAK 1: Preverba gostitelja (SAMO BRANJE)
# ════════════════════════════════════════════════════════════════

step_1() {
    header "Korak 1: Preverba gostitelja (samo branje)"

    local notes=""
    local has_fail=false
    local has_warn=false
    local pve_ver=""
    local kernel_ver=""

    add_note() {
        local level="$1"; shift
        notes="${notes}  [${level}] $*"
        if [[ "$level" == "FAIL" ]]; then has_fail=true; fi
        if [[ "$level" == "WARN" ]]; then has_warn=true; fi
    }

    # ── 1a: Root ──
    if [[ "$EUID" -eq 0 ]]; then
        info "  [PASS] Root: da (EUID=0)"
        add_note "PASS" "Root: da"
    else
        error "  [FAIL] Root: ne (EUID=$EUID) — zaženi z sudo"
        add_note "FAIL" "Root: ne — uporabi sudo"
    fi

    # ── 1b: Proxmox verzija ──
    if cmd_check pveversion; then
        pve_ver=$(pveversion 2>/dev/null | grep '^pve-manager/' | awk '{print $2}' || echo 'unknown')
        info "  [PASS] Proxmox: ${pve_ver}"
        add_note "PASS" "Proxmox: ${pve_ver}"
    else
        error "  [FAIL] Proxmox: pveversion ni na voljo — ni Proxmox gostitelj"
        add_note "FAIL" "Proxmox: pveversion ni na voljo — ni Proxmox gostitelj"
    fi

    # ── 1c: Jedro ──
    if [[ -f /proc/version ]]; then
        kernel_ver=$(uname -r 2>/dev/null || echo 'unknown')
        info "  [INFO] Jedro: ${kernel_ver}"
        add_note "INFO" "Jedro: ${kernel_ver}"
    fi

    # ── 1d: CPU in virtualizacija ──
    if [[ -f /proc/cpuinfo ]]; then
        local cpu_vendor cpu_model virt_type
        cpu_vendor=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
        cpu_model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)
        virt_type="fizikalni"
        if grep -qiE 'hypervisor|bhyve|kvm|vmware|xen|qemu' /proc/cpuinfo 2>/dev/null; then
            virt_type="virtualiziran (kvm/hypervisor zaznan)"
        fi
        info "  [PASS] CPU: ${cpu_model} (${cpu_vendor})"
        info "  [PASS] Virtualizacija: ${virt_type}"
        add_note "PASS" "CPU: ${cpu_model} (${cpu_vendor}), virtualizacija: ${virt_type}"
    else
        warn "  [WARN] CPU: /proc/cpuinfo ni na voljo"
        add_note "WARN" "CPU: /proc/cpuinfo ni na voljo"
    fi

    # ── 1e: IOMMU ──
    local iommu_status="FAIL"
    local iommu_detail=""
    if grep -qE 'intel_iommu=on|iommu=pt|amd_iommu=on|amd_iommu=pt' /proc/cmdline 2>/dev/null; then
        iommu_detail="cmdline: vklopljen"
        iommu_status="PASS"
    elif dmesg 2>/dev/null | grep -qi 'DMAR|AMD-Vi.*IOMMU'; then
        iommu_detail="dmesg: IOMMU zaznan"
        iommu_status="WARN"
    else
        iommu_detail="ne zaznan v cmdline ali dmesg"
    fi

    if [[ "$iommu_status" == "PASS" ]]; then
        info "  [PASS] IOMMU: ${iommu_detail}"
        add_note "PASS" "IOMMU: ${iommu_detail}"
    else
        warn "  [WARN] IOMMU: ${iommu_detail}"
        add_note "WARN" "IOMMU: ${iommu_detail} — priporočilo: dodaj 'intel_iommu=on iommu=pt' v /etc/default/grub in 'update-grub'"
    fi

    # ── 1f: Zagonski nalagalnik ──
    if [[ -d /sys/firmware/efi ]]; then
        if [[ -f /etc/kernel/proxmox-boot-uuids ]]; then
            info "  [PASS] Bootloader: UEFI (proxmox-boot-tool / systemd-boot)"
            info "  Priporočilo po spremembi: proxmox-boot-tool refresh"
            add_note "PASS" "Bootloader: UEFI (proxmox-boot-tool) — refresh: proxmox-boot-tool refresh"
        else
            info "  [PASS] Bootloader: UEFI (GRUB)"
            info "  Priporočilo po spremembi: update-grub"
            add_note "PASS" "Bootloader: UEFI (GRUB) — refresh: update-grub"
        fi
    else
        info "  [PASS] Bootloader: BIOS (GRUB)"
        info "  Priporočilo po spremembi: update-grub"
        add_note "PASS" "Bootloader: BIOS (GRUB) — refresh: update-grub"
    fi

    # ── 1g: /etc/modules in /etc/modules-load.d — podvojene/okvarjene vrstice ──
    local modules_issues=""
    # /etc/modules
    if [[ -f /etc/modules ]]; then
        local bad_lines
        bad_lines=$(grep -nE '^-e\b|\s-e\b|^[[:space:]]*#|^[[:space:]]*$' /etc/modules 2>/dev/null || true)
        if [[ -n "$bad_lines" ]]; then
            modules_issues="${modules_issues}  /etc/modules: "
            while IFS= read -r bl; do
                modules_issues="${modules_issues}${bl} "
            done <<< "$bad_lines"
        fi
        # Podvojene vrstice (ignoriraj komentarje)
        local dup_lines
        dup_lines=$(grep -vE '^\s*#|^\s*$' /etc/modules 2>/dev/null | sort | uniq -d || true)
        if [[ -n "$dup_lines" ]]; then
            modules_issues="${modules_issues}  /etc/modules (podvojene): ${dup_lines}"
        fi
    fi
    # /etc/modules-load.d
    if [[ -d /etc/modules-load.d ]]; then
        for modfile in /etc/modules-load.d/*.conf; do
            [[ -f "$modfile" ]] || continue
            local bad_ml
            bad_ml=$(grep -nE '^-e\b|\s-e\b' "$modfile" 2>/dev/null || true)
            if [[ -n "$bad_ml" ]]; then
                modules_issues="${modules_issues}  ${modfile}: ${bad_ml}"
            fi
        done
    fi
    if [[ -n "$modules_issues" ]]; then
        warn "  [WARN] Moduli konfiguracija — okvarjene/podvojene vrstice:${modules_issues}"
        add_note "WARN" "Moduli: okvarjene/podvojene vrstice — priporočilo: ročno popravi /etc/modules in /etc/modules-load.d/*.conf"
    else
        info "  [PASS] Moduli konfiguracija: brez očitnih napak"
        add_note "PASS" "Moduli konfiguracija: brez očitnih napak"
    fi

    # ── 1h: vfio_virqfd — ali obstaja v modinfo ──
    if cmd_check modinfo; then
        if modinfo vfio_virqfd &>/dev/null; then
            info "  [PASS] vfio_virqfd: modul obstaja za to jedro"
            add_note "PASS" "vfio_virqfd: modul obstaja"
        else
            info "  [INFO] vfio_virqfd: modul ne obstaja za to jedro (normalno, če jedro ne podpira)"
            add_note "INFO" "vfio_virqfd: modul ne obstaja za to jedro"
        fi
    fi

    # ── 1i: Črni seznam GPU gonilnikov ──
    local blacklist_ok=true
    local blacklist_details=""
    # Preveri vse modprobe konfiguracije za črni seznam nouveau, nvidia-nouveau, nvidiafb, nova_core
    for driver in nouveau nvidia-nouveau nvidiafb nova_core; do
        local found_blacklist=false
        if grep -rqE "^blacklist\s+${driver}\s*$" /etc/modprobe.d/ 2>/dev/null; then
            found_blacklist=true
        fi
        if [[ "$found_blacklist" == "true" ]]; then
            blacklist_details="${blacklist_details}${driver} "
        else
            blacklist_ok=false
            blacklist_details="${blacklist_details}${driver}(MANJKAJ) "
        fi
    done
    if [[ "$blacklist_ok" == "true" ]]; then
        info "  [PASS] Črni seznam GPU gonilnikov: ${blacklist_details}"
        add_note "PASS" "Črni seznam: ${blacklist_details}"
    else
        warn "  [WARN] Črni seznam GPU gonilnikov: ${blacklist_details}"
        add_note "WARN" "Črni seznam: manjkajoči -> ${blacklist_details} — priporočilo: dodaj 'blacklist <driver>' v /etc/modprobe.d/blacklist-gpu.conf"
    fi

    # ── 1j: options vfio-pci ids= ──
    if grep -rqE "^options\s+vfio-pci\s+ids=" /etc/modprobe.d/ 2>/dev/null; then
        local vfio_ids_line
        vfio_ids_line=$(grep -rE "^options\s+vfio-pci\s+ids=" /etc/modprobe.d/ 2>/dev/null | head -1)
        info "  [PASS] vfio-pci ids: ${vfio_ids_line}"
        add_note "PASS" "vfio-pci ids: nastavljen"
    else
        warn "  [WARN] vfio-pci ids: ni 'options vfio-pci ids=' v /etc/modprobe.d/"
        add_note "WARN" "vfio-pci ids: ni nastavljen — priporočilo: 'options vfio-pci ids=<PCI_VENDOR>:<PCI_DEVICE>' v /etc/modprobe.d/vfio-pci.conf"
    fi

    # ── 1k: Zaznan GPU ──
    if cmd_check lspci; then
        local gpus
        gpus=$(lspci 2>/dev/null | grep -iE '3d|vga|nvidia|amd|radeon' || true)
        if [[ -n "$gpus" ]]; then
            info "  [PASS] GPU(s) zaznani:"
            echo "$gpus" | while IFS= read -r g; do echo "    $g"; done
            add_note "PASS" "GPU(s): $(echo "$gpus" | wc -l) zaznano"

            # IOMMU skupina
            local gpu_slot
            gpu_slot=$(echo "$gpus" | head -1 | awk '{print $1}')
            if [[ -n "$gpu_slot" ]] && [[ -d "/sys/bus/pci/devices/0000:${gpu_slot}/iommu_group" ]]; then
                local iommu_group_link iommu_group
                iommu_group_link=$(readlink "/sys/bus/pci/devices/0000:${gpu_slot}/iommu_group" || true)
                iommu_group=$(basename "$iommu_group_link")
                local group_devices
                group_devices=$(ls "/sys/bus/pci/devices/0000:${gpu_slot}/iommu_group/" 2>/dev/null | wc -l)
                if [[ "$group_devices" -gt 2 ]]; then
                    warn "  [WARN] IOMMU skupina ${iommu_group}: ${group_devices} naprav (deli si z drugimi napravami — passthrough morda ne deluje)"
                    add_note "WARN" "IOMMU skupina ${iommu_group}: ${group_devices} naprav — preveri ali so vse namenjene passthroughu"
                else
                    info "  [PASS] IOMMU skupina ${iommu_group}: ${group_devices} naprav"
                    add_note "PASS" "IOMMU skupina ${iommu_group}: ${group_devices} naprav"
                fi
            fi

            # Gonilnik vezan na GPU
            if [[ -n "$gpu_slot" ]] && [[ -d "/sys/bus/pci/devices/0000:${gpu_slot}/driver" ]]; then
                local driver_link driver
                driver_link=$(readlink "/sys/bus/pci/devices/0000:${gpu_slot}/driver" || true)
                driver=$(basename "$driver_link")
                case "$driver" in
                    vfio-pci)
                        info "  [PASS] GPU gonilnik: ${driver} (pravilno za passthrough)"
                        add_note "PASS" "GPU gonilnik: ${driver}"
                        ;;
                    nouveau|nvidia)
                        warn "  [WARN] GPU gonilnik: ${driver} — za passthrough naj bi bil vfio-pci"
                        add_note "WARN" "GPU gonilnik: ${driver} — priporočilo: dodaj ${driver}=modeset=0 in vfio-pci ids=... v modprobe"
                        ;;
                    *)
                        info "  [INFO] GPU gonilnik: ${driver}"
                        add_note "INFO" "GPU gonilnik: ${driver}"
                        ;;
                esac
            fi
        else
            warn "  [WARN] GPU: ni zaznanega NVIDIA/AMD GPU (lspci)"
            add_note "WARN" "GPU: ni zaznanega NVIDIA/AMD GPU — preveri PCI passthrough"
        fi
    else
        warn "  [WARN] lspci ni na voljo — GPU preverba preskočena"
        add_note "WARN" "lspci ni na voljo"
    fi

    # ── 1l: vfio moduli ──
    if lsmod 2>/dev/null | grep -q vfio; then
        local vfio_mods
        vfio_mods=$(lsmod | grep vfio | awk '{print $1}' | tr '\n' ', ')
        info "  [PASS] vfio moduli: ${vfio_mods}"
        add_note "PASS" "vfio moduli: ${vfio_mods}"
    else
        info "  [INFO] vfio moduli: nobeden naložen (normalno, če GPU še ni dodeljen)"
        add_note "INFO" "vfio moduli: nobeden naložen"
    fi

    # ── 1m: Shramba ──
    if cmd_check pvesm; then
        local pvesm_out
        pvesm_out=$(pvesm status 2>/dev/null || echo 'napaka pri branju')
        info "  [PASS] Shramba (pvesm status):"
        echo "$pvesm_out" | head -5 | while IFS= read -r line; do echo "    $line"; done
        add_note "PASS" "Shramba: $(echo "$pvesm_out" | head -1)"

        # Preveri prosti prostor (vsaj 200 GiB)
        local total_avail_gb=0
        # Seštej Avail v GB iz pvesm status (preskoči header)
        total_avail_gb=$(echo "$pvesm_out" | tail -n +2 | awk '{sum += $4} END {printf "%.0f", sum}')
        if [[ "$total_avail_gb" -ge 200 ]]; then
            info "  [PASS] Prosti prostor: ${total_avail_gb} GiB (zahtevano ≥200 GiB)"
            add_note "PASS" "Prosti prostor: ${total_avail_gb} GiB"
        else
            warn "  [WARN] Prosti prostor: ${total_avail_gb} GiB (zahtevano ≥200 GiB)"
            add_note "WARN" "Prosti prostor: ${total_avail_gb} GiB < 200 GiB — priporočilo: sprosti prostor ali dodaj shrambo"
        fi
    else
        warn "  [WARN] pvesm ni na voljo — shramba ni preverjena"
        add_note "WARN" "pvesm ni na voljo — shramba ni preverjena"
    fi

    # ── 1n: RAM ──
    if [[ -f /proc/meminfo ]]; then
        local ram_total
        ram_total=$(grep MemTotal /proc/meminfo | awk '{printf "%.0f GB", $2/1024/1024}')
        info "  [PASS] RAM: ${ram_total}"
        add_note "PASS" "RAM: ${ram_total}"
    else
        warn "  [WARN] RAM: /proc/meminfo ni na voljo"
        add_note "WARN" "RAM: ne preverjeno"
    fi

    # ── 1o: VM-ji z hostpci ──
    if cmd_check qm; then
        local vm_list
        vm_list=$(qm list 2>/dev/null | tail -n +2 || true)
        if [[ -n "$vm_list" ]]; then
            local found_pci=false
            while IFS=' ' read -r vmid rest; do
                vmid=$(echo "$vmid" | tr -d ' ')
                [[ -z "$vmid" ]] && continue
                local pci_config
                pci_config=$(qm config "$vmid" 2>/dev/null | grep 'hostpci' || true)
                if [[ -n "$pci_config" ]]; then
                    if [[ "$found_pci" == "false" ]]; then
                        info "  [INFO] VM-ji z hostpci:"
                        found_pci=true
                    fi
                    echo "    VM ${vmid}: ${pci_config}"
                fi
            done <<< "$vm_list"
            if [[ "$found_pci" == "true" ]]; then
                add_note "INFO" "Obstajajo VM-ji z hostpci — preveri ali uporabljajo isti GPU"
            fi
        else
            info "  [INFO] VM-ji: nobeden (prazna lista)"
            add_note "INFO" "VM-ji: nobeden"
        fi
    else
        warn "  [WARN] qm ni na voljo — VM pregled preskočen"
        add_note "WARN" "qm ni na voljo — VM pregled preskočen"
    fi

    # ── 1p: Dostop do zunanjih storitev ──
    for url_name in "github.com:443" "ghcr.io:443" "raw.githubusercontent.com:443"; do
        local host
        host="${url_name%%:*}"
        if curl -sI --connect-timeout 5 "https://${host}" &>/dev/null; then
            info "  [PASS] Dostop: ${url_name}"
            add_note "PASS" "Dostop: ${url_name}"
        else
            warn "  [WARN] Dostop: ${url_name} — ne dosegljiv (curl timeout/napaka)"
            add_note "WARN" "Dostop: ${url_name} ne dosegljiv — preveri firewall/proksi"
        fi
    done

    # ── 1q: BIOS kontrolni seznam ──
    echo ""
    echo -e "${BOLD}  BIOS/UEFI kontrolni seznam [NEPREVERJENO]:${RESET}"
    echo "    [ ] VT-d / AMD-Vi (IOMMU) — vklopljeno"
    echo "    [ ] Above 4G Decoding — vklopljeno (potreben za GPU passthrough)"
    echo "    [ ] UEFI — vklopljeno (priporočeno namesto BIOS/CSM)"
    echo "    [ ] Secure Boot — izklopljeno (za NVIDIA gonilnike brez MOK enrollment)"
    echo ""

    # ── Dodaj verzije v poročilo ──
    if [[ -n "$pve_ver" ]]; then
        notes="${notes}  [INFO] PVE verzija: ${pve_ver}"
    fi
    if [[ -n "$kernel_ver" ]]; then
        notes="${notes}  [INFO] Jedro: ${kernel_ver}"
    fi

    # Končni status
    if [[ "$has_fail" == "true" ]]; then
        STEP_STATUS="FAIL"
    elif [[ "$has_warn" == "true" ]]; then
        STEP_STATUS="WARN"
    else
        STEP_STATUS="PASS"
    fi

    save_step_report 1 "Preverba gostitelja" "$STEP_STATUS" "$notes"
}

# ════════════════════════════════════════════════════════════════
#  KORAKI 2–9: Ogrinjala (še ni implementirano)
# ════════════════════════════════════════════════════════════════

step_not_implemented() {
    local step_num="$1"
    local step_name="$2"
    header "Korak ${step_num}: ${step_name}"
    warn "Še ni implementirano."
    echo ""
    STEP_STATUS="PASS"
    STEP_NOTES="Korak ${step_num}: še ni implementirano"
    save_step_report "$step_num" "$step_name" "$STEP_STATUS" "$STEP_NOTES"
}

step_2() { step_not_implemented 2 "Passthrough priprava (vfio, GPU dodelitev)"; }
step_3() { step_not_implemented 3 "Deploy key (GitHub read-only SSH)"; }
step_4() { step_not_implemented 4 "GHCR token (classic PAT, read:packages)"; }
step_5() { step_not_implemented 5 "Ustvarjanje VM (ubuntu-vm.sh)"; }
step_6() { step_not_implemented 6 "GPU v VM (qm set --hostpci0)"; }
step_7() { step_not_implemented 7 "IP in prva prijava (DHCP, ssh-keygen -R)"; }
step_8() { step_not_implemented 8 "Namestitev v VM (bootstrap.sh + setup.sh)"; }
step_9() { step_not_implemented 9 "Zaključek (preverbe, poročilo)"; }

# ════════════════════════════════════════════════════════════════
#  GLAVNA ZANKA
# ════════════════════════════════════════════════════════════════

main() {
    # Brez argumentov → uporaba
    if [[ $# -eq 0 ]]; then
        usage
        exit 0
    fi

    WIZARD_HASH="$SCRIPT_HASH"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)
                list_steps
                exit 0
                ;;
            --step)
                if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]$ ]]; then
                    error "Neveljaven korak: $2 (pričakovano 0–9)"
                    exit 1
                fi
                CURRENT_STEP="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                info "Dry-run način: spremembe ne bodo shranjene."
                shift
                ;;
            --resume)
                # Naloži PREFIX iz state (nato izračunaj naslednji korak)
                if [[ -d "$INSTALL_DIR" ]]; then
                    if load_state; then
                        local last_step
                        local sf
                        sf=$(find "$INSTALL_DIR" -maxdepth 1 -name '*state.env' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2 || true)
                        last_step=$(grep '^LAST_COMPLETED_STEP=' "$sf" 2>/dev/null | head -1 | cut -d= -f2 || echo 0)
                        CURRENT_STEP=$((last_step + 1))
                        if [[ "$CURRENT_STEP" -gt 9 ]]; then
                            info "Vsi koraki zaključeni."
                            exit 0
                        fi
                        info "Nadaljevanje od koraka ${CURRENT_STEP} (predpona: ${PREFIX})"
                    else
                        warn "Ni obstoječega stanja. Začni s korakom 0."
                        CURRENT_STEP=0
                    fi
                else
                    warn "Ni stanja za nadaljevanje. Začni s korakom 0."
                    CURRENT_STEP=0
                fi
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                error "Neznano stikalo: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Brez --step in brez --resume → uporaba
    if [[ -z "${CURRENT_STEP:-}" ]]; then
        usage
        exit 0
    fi

    # Log datoteka (samo če ni dry-run)
    if [[ "$DRY_RUN" != "true" ]] && [[ -n "${PREFIX:-}" ]]; then
        init_state_dir
        exec >> "${INSTALL_DIR}/${PREFIX}install.log" 2>&1
    elif [[ "$DRY_RUN" != "true" ]]; then
        init_state_dir
    fi

    info "e-dragon-llm-node install wizard v${WIZARD_VERSION} (hash: ${WIZARD_HASH:0:12}...)"
    info "Imenik stanja: ${INSTALL_DIR}"
    if [[ -n "${PREFIX:-}" ]]; then
        info "Predpona: ${PREFIX}"
    fi

    # Naloži stanje (korak ≥1 potrebuje PREFIX iz koraka 0)
    if [[ "$CURRENT_STEP" -ge 1 ]]; then
        load_state
    fi

    # Izvedi korak
    case "$CURRENT_STEP" in
        0) step_0 ;;
        1) step_1 ;;
        2) step_2 ;;
        3) step_3 ;;
        4) step_4 ;;
        5) step_5 ;;
        6) step_6 ;;
        7) step_7 ;;
        8) step_8 ;;
        9) step_9 ;;
        *)
            error "Neveljaven korak: ${CURRENT_STEP}"
            exit 1
            ;;
    esac

    # Posodobi stanje (samo pri koraku 0)
    if [[ "$CURRENT_STEP" == "0" ]] && [[ "$DRY_RUN" != "true" ]] && [[ "$STEP_STATUS" == "PASS" ]]; then
        local state_file="${INSTALL_DIR}/${PREFIX}state.env"
        if [[ -f "$state_file" ]]; then
            sed -i "s/^LAST_COMPLETED_STEP=.*/LAST_COMPLETED_STEP=${CURRENT_STEP}/" "$state_file"
        fi
    fi

    info "Čarovnik končan."
}

main "$@"
