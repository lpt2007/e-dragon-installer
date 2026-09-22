# e-dragon-installer

Čarovnik za namestitev e-dragon-llm-node na Proxmox gostitelje strank.

## Kaj je?

`install-wizard.sh` je samostojna Bash skripta, ki vodi upravitelja skozi korake namestitve:

1. **Korak 0** — Identifikacija stranke (ime, pogodba, predpona)
2. **Korak 1** — Preverba gostitelja (Proxmox, GPU, IOMMU, shramba)
3. **Koraki 2–9** — Passthrough, ključi, VM, GPU, IP, namestitev, zaključek

Brez veljavnega GitHub ključa za pisanje skripta ne more biti spremenjena — vsaka izdaja ima SHA256 hash, ki ga preverite pred zagonom.

## Prenos izdaje

Izdaje so objavljene na [GitHub Releases](https://github.com/lpt2007/e-dragon-installer/releases).

```bash
# 1. Prenesite izdajo
wget https://github.com/lpt2007/e-dragon-installer/releases/download/v0.1.0/install-wizard.sh

# 2. Preverite SHA256 hash (primer — primerjajte z vrednostjo na strani Release)
sha256sum install-wizard.sh

# 3. Dovolite zagon
chmod +x install-wizard.sh

# 4. Zaženite (zahteva sudo)
sudo ./install-wizard.sh --list
```

## Uporaba

```bash
# Seznam vseh korakov
sudo ./install-wizard.sh --list

# Izvedi posamezen korak
sudo ./install-wizard.sh --step 0

# Nadaljuj od zadnjega koraka
sudo ./install-wizard.sh --resume

# Predogled brez sprememb
sudo ./install-wizard.sh --step 1 --dry-run
```

## Zaščita

- Repo `main` je zaščiten — neposredni push v `main` ni mogoč.
- Razvoj poteka v veji `dev`.
- Skripta ne zahteva GitHub ključa za delovanje — deluje samostojno na ciljnem Proxmox gostitelju.
