#!/usr/bin/env python3
"""org-readme.py - atualiza a seção "Baixar a ISO" do README da organização.

Uso:
  org-readme.py --tag <tag> [--repo dono/repo] <profile/README.md>
  org-readme.py --self-test

Lê da release publicada (gh release view/download) os nomes e tamanhos das
partes .7z e o SHA256SUMS, e reescreve no README, no lugar, o que muda a cada
ISO: links e tag, nome da ISO nos comandos, data, mês e kernel da versão
atual, tamanho da ISO, número de partes, a tabela de partes e o SHA-256 da
ISO (minúsculo e, no PowerShell, maiúsculo). Nada é digitado à mão: a soma
vem do SHA256SUMS da própria release. O resto do texto não é tocado.

O README atual precisa ter uma versão anterior no mesmo formato (o script
acha a tag, o nome da ISO e a soma antigos nele). Termina com erro se algum
trecho esperado não for encontrado, em vez de gravar um README pela metade.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

MESES = ("janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho",
         "agosto", "setembro", "outubro", "novembro", "dezembro")
NUMEROS = {2: "duas", 3: "três", 4: "quatro", 5: "cinco"}
TAG_RE = re.compile(r"^(?P<base>[A-Za-z0-9][A-Za-z0-9._-]*_(?P<a>\d{4})-(?P<m>\d{2})-(?P<d>\d{2})"
                    r"_k(?P<kmaj>\d)(?P<kmin>\d+))-r\d+$")


class Erro(Exception):
    pass


def _virgula(valor: float, casas: int) -> str:
    return f"{valor:.{casas}f}".replace(".", ",")


def _sub1(padrao: str, novo, texto: str, o_que: str, flags: int = 0) -> str:
    texto, n = re.subn(padrao, novo, texto, flags=flags)
    if n == 0:
        raise Erro(f"trecho não encontrado no README: {o_que}")
    return texto


def atualizar(texto: str, tag: str, repo: str, tamanhos: dict[str, int], sums: str) -> str:
    m = TAG_RE.match(tag)
    if not m:
        raise Erro(f"tag fora do formato <nome>_AAAA-MM-DD_kNNN-rN: {tag}")
    base = m["base"]
    iso = base + ".iso"
    somas = {}
    for linha in sums.splitlines():
        partes = linha.split()
        if len(partes) == 2 and re.fullmatch(r"[0-9a-f]{64}", partes[0]):
            somas[partes[1].lstrip("*")] = partes[0]
    if iso not in somas:
        raise Erro(f"{iso} não está no SHA256SUMS")
    soma = somas[iso]
    pedacos = sorted(n for n in tamanhos if re.fullmatch(re.escape(iso) + r"\.7z\.\d{3}", n))
    if not pedacos or "SHA256SUMS" not in tamanhos:
        raise Erro("a release não tem as partes .7z e o SHA256SUMS")
    if len(pedacos) not in NUMEROS:
        raise Erro(f"{len(pedacos)} partes: sem palavra para esse número")
    # partes .001, .002, ... sem buracos, as mesmas que o SHA256SUMS registra
    if pedacos != [f"{iso}.7z.{i:03d}" for i in range(1, len(pedacos) + 1)] or \
            set(pedacos) != {n for n in somas if n.startswith(iso + ".7z.")}:
        raise Erro(f"partes .7z incompletas ou diferentes do SHA256SUMS: {', '.join(pedacos)}")

    # Só a seção de download (de "Baixar a ISO" até o fim de "Gravar no
    # pendrive", onde está o dd) muda; o histórico de novidades fica como está.
    ini = texto.find("\n## 📥 Baixar a ISO")
    gravar = texto.find("\n## 💾 Gravar no pendrive", ini + 1)
    fim = texto.find("\n## ", gravar + 1) if gravar > 0 else -1
    if ini < 0 or gravar < 0:
        raise Erro("seções \"Baixar a ISO\" e \"Gravar no pendrive\" não encontradas")
    fim = len(texto) if fim < 0 else fim
    topo, secao, resto = texto[:ini], texto[ini:fim], texto[fim:]

    antiga = re.search(r"releases/tag/([A-Za-z0-9][A-Za-z0-9._-]*-r\d+)\"", secao)
    if not antiga:
        raise Erro("o README não tem a tag da versão anterior")
    tag_antiga, base_antiga = antiga[1], re.sub(r"-r\d+$", "", antiga[1])
    secao = secao.replace(tag_antiga, tag).replace(base_antiga, base)
    # As duas somas são trocadas cada uma no seu lugar, seja qual for o valor
    # antigo (já estiveram diferentes entre si).
    secao = _sub1(r"(SHA-256 da ISO:\n`)[0-9a-f]{64}(`)", lambda x: x[1] + soma + x[2], secao,
                  "SHA-256 da ISO")
    secao = _sub1(r"(O resultado precisa ser igual a:\n\n\s*```text\n\s*)[0-9A-Fa-f]{64}\n",
                  lambda x: x[1] + soma.upper() + "\n", secao, "SHA-256 do PowerShell")

    data = f"{m['d']}/{m['m']}/{m['a']}"
    mes = MESES[int(m["m"]) - 1]
    kernel = f"{m['kmaj']}.{m['kmin']}"
    secao = _sub1(r"(\*\*Versão atual:\*\* Big WindowMaker \*\*Alpha de )[^*]+(\*\* \()"
                  r"\d{2}/\d{2}/\d{4}, kernel [0-9.]+\)",
                  lambda x: f"{x[1]}{mes}{x[2]}{data}, kernel {kernel})", secao, "Versão atual")
    secao = _sub1(r"Alpha%20de%20\d{2}%2F\d{2}%2F\d{4}", "Alpha%20de%20" + data.replace("/", "%2F"),
                  secao, "botão Baixar")
    secao = _sub1(r"Baixar a Alpha de \d{2}/\d{2}/\d{4}", "Baixar a Alpha de " + data, secao,
                  "texto do botão Baixar")
    topo = _sub1(r"ISO-Alpha%20de%20[^-\"]+-", f"ISO-Alpha%20de%20{mes.replace('ç', '%C3%A7')}-",
                  topo, "selo do topo")
    topo = _sub1(r'alt="ISO Alpha de [^"]+"', f'alt="ISO Alpha de {mes}"', topo, "selo do topo (alt)")

    total = sum(tamanhos[n] for n in pedacos)  # 7z -mx=0: a ISO mais ~200 bytes
    secao = _sub1(r"A ISO tem [0-9,]+ GiB \([0-9,]+ GB\)",
                  f"A ISO tem {_virgula(total / 2**30, 1)} GiB ({_virgula(total / 1e9, 1)} GB)",
                  secao, "tamanho da ISO")
    palavra = NUMEROS[len(pedacos)]
    secao = _sub1(r"\b(duas|três|quatro|cinco)( partes)", lambda x: palavra + x[2], secao, "número de partes")
    secao = re.sub(r"(Baixe as )(duas|três|quatro|cinco)( para)", lambda x: x[1] + palavra + x[3], secao)

    url = f"https://github.com/{repo}/releases/download/{tag}"
    linhas = [f"| [`{n}`]({url}/{n}) | {_virgula(tamanhos[n] / 1e9, 2)} GB |" for n in pedacos]
    tabela = re.compile(r"^\| \[`[^`]+\.iso\.7z\.\d{3}`\]\([^)]*\) \| [^|]+ \|\n", re.M)
    inicio = tabela.search(secao)
    if not inicio:
        raise Erro("tabela de partes não encontrada")
    secao = tabela.sub("", secao)
    secao = secao[:inicio.start()] + "\n".join(linhas) + "\n" + secao[inicio.start():]
    return topo + secao + resto


def _gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def _amostra() -> str:
    t = "big-windowmaker_TESTING_2026-11-24_k618-r62"
    b = "big-windowmaker_TESTING_2026-11-24_k618.iso"
    u = f"https://github.com/big-windowmaker/build-iso/releases/download/{t}"
    return (
        '<img src="https://img.shields.io/badge/ISO-Alpha%20de%20novembro-8a2be2" alt="ISO Alpha de novembro">\n'
        "\n## 📥 Baixar a ISO\n\n"
        "**Versão atual:** Big WindowMaker **Alpha de novembro** (24/11/2026, kernel 6.18).\n"
        f'<a href="https://github.com/big-windowmaker/build-iso/releases/tag/{t}"><img src="https://img.shields.io/badge/'
        'Baixar-Alpha%20de%2024%2F11%2F2026-8a2be2?style=for-the-badge" alt="Baixar a Alpha de 24/11/2026"></a>\n'
        "A ISO tem 4,9 GiB (5,3 GB) e vem em\n**três partes `.7z`**. Baixe as três para a mesma pasta\n"
        "| Arquivo | Tamanho |\n|---|---|\n"
        + "".join(f"| [`{b}.7z.00{i}`]({u}/{b}.7z.00{i}) | 2,0 GB |\n" for i in (1, 2, 3))
        + f"| [`SHA256SUMS`]({u}/SHA256SUMS) | somas de verificação |\n"
        f"7z x {b}.7z.001\nGet-FileHash .\\{b} -Algorithm SHA256\n\n"
        f"4. O resultado precisa ser igual a:\n\n   ```text\n   {'AB' * 32}\n   ```\n"
        f"SHA-256 da ISO:\n`{'cd' * 32}`\n"
        f"\n## 💾 Gravar no pendrive\n\nsudo dd if={b} of=/dev/sdX\n"
        f"\n## 🆕 Novo na ISO de 24/11\n\nNotas da [r62](https://github.com/big-windowmaker/build-iso/releases/tag/{t}).\n")


def self_test() -> None:
    tag = "big-windowmaker_TESTING_2026-12-03_k618-r70"
    iso = "big-windowmaker_TESTING_2026-12-03_k618.iso"
    tamanhos = {f"{iso}.7z.001": 2097152000, f"{iso}.7z.002": 1100000000, "SHA256SUMS": 900}
    soma = "c0" * 32
    sums = f"{soma}  {iso}\n{'11' * 32}  {iso}.7z.001\n{'22' * 32}  {iso}.7z.002\n"
    novo = atualizar(_amostra(), tag, "big-windowmaker/build-iso", tamanhos, sums)
    for esperado in (f"releases/tag/{tag}\"", "Alpha de dezembro** (03/12/2026, kernel 6.18).",
                     "Alpha%20de%2003%2F12%2F2026", "Baixar a Alpha de 03/12/2026",
                     "ISO-Alpha%20de%20dezembro-", "A ISO tem 3,0 GiB (3,2 GB)", "**duas partes",
                     "Baixe as duas para", "| 1,10 GB |", f"7z x {iso}.7z.001", f".\\{iso} -Algorithm",
                     f"   {soma.upper()}\n", f"`{soma}`", f"dd if={iso} "):
        assert esperado in novo, (esperado, novo)
    assert novo.count(".7z.00") == 2 + 2 + 1, novo  # 2 linhas (nome + link) + o comando 7z x
    # as somas antigas (diferentes entre si) somem; o histórico mantém a r62
    assert "AB" * 32 not in novo and "cd" * 32 not in novo
    assert novo.count("k618-r62") == 1 and "Notas da [r62](" in novo
    ruins = (("", tamanhos),  # SHA256SUMS sem a ISO
             (sums, {**tamanhos, f"{iso}.7z.004": 5}),  # buraco: falta a .003
             (f"{soma}  {iso}\n{'11' * 32}  {iso}.7z.001\n", tamanhos))  # parte fora do SHA256SUMS
    for s, tam in ruins:
        try:
            atualizar(_amostra(), tag, "x/y", tam, s)
        except Erro:
            continue
        raise AssertionError(f"aceitou uma release inconsistente: {sorted(tam)}")
    print("org-readme.py: self-test ok")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tag")
    ap.add_argument("--repo", default="big-windowmaker/build-iso")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("readme", nargs="?", type=Path)
    a = ap.parse_args()
    if a.self_test:
        self_test()
        return 0
    if not a.tag or not a.readme:
        ap.error("--tag e o caminho do README são obrigatórios")
    assets = json.loads(_gh("release", "view", a.tag, "-R", a.repo, "--json", "assets"))["assets"]
    tamanhos = {x["name"]: x["size"] for x in assets}
    sums = _gh("release", "download", a.tag, "-R", a.repo, "-p", "SHA256SUMS", "-O", "-")
    try:
        novo = atualizar(a.readme.read_text(encoding="utf-8"), a.tag, a.repo, tamanhos, sums)
    except Erro as e:
        print(f"org-readme.py: erro: {e}", file=sys.stderr)
        return 1
    a.readme.write_text(novo, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
