# 🧭 Generell mall för ett autonomt agent-projekt

> Ett skelett för projekt där ett team av agenter kör självständigt, GPU-tungt och över flera nätter.
> Alla mönster nedan är beprövade i skarp drift, inte teori. Systerdokument: [`README.md`](README.md)
> (Gud/host-rollen).

---

## 1. Grundfilosofi

Ett autonomt agent-projekt ska kunna **köra självt över natten, krascha, och vakna igen utan att ha
gjort något dumt eller oåterkalleligt**. Tre pelare:

1. **Inlåsning** — agenterna kan inte skada utomstående system även om de vill/felar.
2. **Resumbarhet** — ingen körning kan spilla en hel natt; allt går att återuppta.
3. **Synlighet** — människan ser läget (dashboard, skiftrapport, notiser) utan att gräva.

---

## 2. Katalogstruktur

```
projekt_env/
├── WAKE.md                 # ingång: "läs WAKE och börja jobba" (roller + flöde + hårda regler)
├── skiftrapport.md         # append-only logg, en rad per händelse (vem/tid/vad) — teamets minne
├── _projektmall/           # mall för nya delprojekt (kopiera & fyll)
├── secrets/                # tokens per fil (aldrig i git), + en README som förklarar mappen
├── gemensamt/              # delat: agentverktyg/ (notify.py…), referensmaterial, dashboard-hub
└── <delprojekt>/
    ├── STATUS.md           # var vi är, klartext
    ├── agent/              # arbetsflöde, beslutslogg, persistens_och_resumbarhet.md
    ├── plan/               # dygnsrytm.md, nastasteg.md, pipeline_state.json, morgondigest.md
    ├── configs/            # all konfig i filer (inga magiska tal i koden)
    ├── src/{common,data,modeller,pipeline}/
    ├── experiment/         # metrics/*.jsonl, loggar, <analys>.md, kritik
    ├── modeller/           # checkpoints, best-vikter, result.json per runda
    ├── nattkörning.py      # nattens jobbkö
    ├── nattvakt.py         # extern watchdog
    └── scripts/            # start.sh, efter_omstart.sh, morgonanalys.sh
```

Konvention: en kort **"vad hör hit"-fil** i varje mapp som förklarar vad som hör hemma där. Håller ett
självkörande team orienterat.

---

## 3. Inlåsning — den säkra containern som "burar in" agenten

Målet: en agent som kan koda, träna och köra fritt **inne**, men inte kan nå produktion eller skada
host. Recept:

- **Ej privilegierad.** Inga extra capabilities, `--ipc=private`, ingen `--privileged`.
- **Isolerat nät utan exponerade portar.** Eget docker-nät; publicera *inga* portar till host/internet.
  Interna tjänster (dashboard, DB) nås bara på nätet via containernamn.
- **Bara projektkatalogen monterad** (`-v …/kod:/workspace/kod`), inte hela hemmet. Allt utanför
  mounten är efemärt → en recreate nollställer ev. skada.
- **Hård minnesgräns** (`--memory`, swap av) så en runaway inte tar hela maskinen.
- **Dev-DB skild från prod.** Agenten når bara dev-instansen (eget namn/port på nätet); prod är osynlig.
- **På unified-memory-GPU** (t.ex. GB10/DGX-klass) kapar cgroup CPU-RAM men **CUDA går förbi cgroupen**
  → ha en host-backstop som GPU-runaway-vakt.
- **STOP-fil som nödbroms** (se §4).

> Effekt: även om en agent felar totalt är radien = containern + mounten. Inget prod, ingen host,
> inga öppna portar.

---

## 4. Säkerhetsgrindar (steg 0, före allt annat)

- **`STOP`-fil:** finns `<delprojekt>/STOP` → agenten gör *ingenting*. Människans nödstopp.
- **Aldrig produktion, aldrig sudo, aldrig SSH utåt** från arbetar-agenten.
- **Stör aldrig en frisk träning.** Optimering får inte döda ett fungerande jobb.
- **Fråga människan via en kanal, inte via UI-block.** Agenten kan inte poppa en dialog — den skickar
  en **notis** (t.ex. Discord/Slack via ett litet `notify.py`) och fortsätter/parkerar.
- **Rollbaserad verktygsåtkomst är den hårda gränsen:** läs-only-roller *saknar Bash i sin
  verktygslista* — de kan fysiskt inte köra kommandon (se §5).

---

## 5. Agent-roller (olika agent för olika ansvar)

| Roll | Ansvar | Kör kommandon? |
|---|---|---|
| **Orkestrerare** | läser läget, dispatchar rätt agent i rätt ordning, håller tråden | JA |
| **Utvecklare** | implementerar + kör träning/inferens, verifierar på urval | JA |
| **Analytiker** | läser resultat/fel/hårdvara → förbättring *inom* arkitekturen | **NEJ** |
| **Forskare** | läser referensmaterial, syntetiserar → föreslår *ny* arkitektur när taket nås | **NEJ** |
| **Kritiker** | inbjuden extern granskare, brutalt ärlig, kalibrerar optimism mot verklighet | **NEJ** |

Principer:
- **Bara två får köra** (orkestrerare + utvecklare). Läs-only-roller får inte Bash — separationen är
  *strukturell*, inte en artighet.
- **Kritikern är inte en löpande roll** utan dispatchas vid milstolpar/lever-beslut. Skriver sin kritik
  till fil; teamet bygger en åtgärdsplan av den. (Ovärderligt för att inte lura sig själv: en ärlig
  extern granskning som möter optimismen med verkligheten.)
- **Analys → beslut → implementation** som ett flöde: ny metrik → analytiker → verdikt
  (`inom_arkitektur` → utvecklare; `arkitektur_tak` → forskare → feasibility → utvecklare).

---

## 6. Persistens & resumbarhet (HÅRD REGEL)

Långa körningar (**>15 min ELLER natt**) MÅSTE:

1. **Startas `setsid`-frånkopplade** (ppid=1) → överlever att människan stänger laptopen / SSH dör.
2. **Vara säkra obevakat** — resursvakt körd **FÖRE** CUDA + GPU-fri-koll; aldrig prod/sudo/SSH. Inget
   farligt får hända medan människan sover.
3. **Vara resumbara** — checkpoint var N steg + resume-logik (`--resume` fortsätter från ck, ej
   omstart). En krasch mitt i natten får inte spilla natten.
4. **Spara best-vikter + `result.json` per runda** — aldrig bara sista steget.

Mönster för en tränare: `--train/--resume`, checkpoint var N steg, best-vikter + result, resursvakt
före CUDA, experiment-tracker på. Bygg detta *innan* första riktiga körningen, och **verifiera att
resume faktiskt fortsätter från checkpoint** (inte börjar om).

---

## 7. Dygnsrytm + nattkörning (optimera GPU/agent över natten)

- **Dag:** korta tester, mätningar, beslut. **Aldrig** ett långt GPU-jobb dagtid.
- **Natt:** tunga jobb via **`nattkörning.py`** — en **levande kö** som redigeras dagtid, startar i
  nattfönstret och skriver en **morgondigest** när människan vaknar (sammanfattning av natten).
- **Mät genomströmning först.** Innan ett flernatts-jobb: kör en kort "probe" som mäter tok/s och VRAM,
  så du vet om det ryms och hur många nätter det tar — istället för att blint binda en hel natt.
- **Deadline-stopp kooperativt:** vid nattfönstrets slut → lägg en **stopp-fil**, vänta (t.ex. 12 min)
  och låt jobbet checkpointa och avsluta självt; SIGTERM först som sista fallback. Aldrig `kill -9`
  mitt i CUDA.

---

## 8. Watchdog + notiser (så en tyst död inte kostar en natt)

Två lager:
1. **In-process** (i jobbkön): signal/exception-handler → notis vid SIGTERM/krasch/jobbfel, och en
   klar-ping.
2. **Extern watchdog** (setsid-frånkopplad): upptäcker **SIGKILL/OOM/hang** via status + heartbeat (som
   in-process-lagret inte kan fånga), pingar "critical", med anti-spam-flagga. Startas automatiskt av
   nattkörningen.

Testa larmen på riktigt (`kill -9` → watchdog ska pinga inom sekunder) — en oprövad larmkedja är ingen
larmkedja.

---

## 9. Resursvakt (cgroup-medveten, före CUDA)

En `resursvakt.py` som:
- **läser containerns riktiga cgroup-tak** (`/sys/fs/cgroup/memory.max`), inte host-totalen,
- gör en **preflight före CUDA** (nog fritt minne? GPU ledig?) och vägrar starta annars,
- har en minnesvakt som primärt vaktar cgroup-headroom, med host-backstop som GPU-runaway-vakt
  (nödvändigt på unified-minne där CUDA går förbi cgroupen).

Regel: **resursvakten körs alltid FÖRE första CUDA-anropet.** Ett jobb som inte får plats ska dö rent i
preflight, inte som en OOM mitt i natten.

---

## 10. Dashboard (håll den levande och uppdaterad)

- **En hub** (HTTP på en intern port) som visar noder/delsteg per projekt (gjort/pågår/att göra),
  senaste analyser (append-only feed), och måltal med *ärlig* chans + tak.
- **En `check`-kommando ska gå exit 0** efter varje uppdatering — en dashboard som ljuger är värre än
  ingen.
- **En experiment-tracker live** (Comet/W&B e.d.) för träningsmetriker — en delbar URL människan kan
  öppna.
- Starta hubben **setsid-frånkopplat** så den överlever; verifiera att endpoints svarar 200.
- Regel: **aldrig idle under träning** — medan GPU jobbar ska agenten uppdatera dashboard/analys/
  dokument, inte vänta passivt.

---

## 11. Bönerummet (inne ↔ host-kommunikation)

Inlåsta agenter kan inte fixa host-problem. Ett **`bönerummet.md`** i mounten är den asynkrona kanalen
till host-agenten. Bra struktur: *symptom → verifieringskommando → känd rotorsak → akut åtgärd →
permanent fix (exakt recept) → koordineringsregler → "append vad du gjorde"*. Skriftligt och i mounten
så det överlever omstarter. (Se `README.md` §5 för host-sidan.)

---

## 12. Loggdisciplin (teamets delade minne)

- **`skiftrapport.md`** — append-only, en rad per händelse: `**HH:MM** (vem) — vad, med siffror`. Detta
  är hur ett team över flera nätter/omstarter håller kontexten. Var konkret: mät, citera tal, notera fel
  *och* läxa.
- **`agent/beslutslogg.md`** — varför-beslut (billigast×nytta-sorterat).
- **`STATUS.md` / `plan/NULÄGE.md`** — nuläget i klartext, alltid uppdaterat.
- **Ärlighet framför optimism.** Logga när baslinjen slår modellen, när en diagnos var fel, när ett tak
  inte var ett tak. Det är så man inte lurar sig själv.

---

## 13. GPU-lärdomar (unified-memory / DGX-klass + generella)

- **cgroup v2 + daemon-reload dödar container-GPU** → använd **CDI** (`--device nvidia.com/gpu=all`),
  inte legacy cgroup-injektion. Recreatas containern, inte bara restartas.
- **Hård-kill mitt i CUDA kan trigga device-droppen** → kooperativ stopp alltid.
- **Unified memory:** GPU-allokeringar är vanligt RAM; ingen separat VRAM-pool. cgroup-minnesgräns kapar
  CPU-RAM men CUDA går förbi den → host-backstop behövs.
- **Ny GPU-arkitektur + äldre framework-build** (saknad PTX för nyaste sm_) → dyr JIT-kompilering per
  anrop om GPU-cachen är avstängd. Slå på persistent kernel-cache på mounten → varm cache.
- **Mät alltid throughput** (tok/s, VRAM) på en liten probe innan du binder nätter.

---

## 14. Checklista — ny maskin / provisionering

1. GPU i container fungerar? (`docker exec … python3 -c "import torch;print(torch.cuda.is_available())"`)
2. Container skapad med **CDI** + rätt mounts/minne/nät + namn?
3. Dev-DB skild från prod, nåbar bara på internnätet?
4. Secrets på plats (per-fil), utan att någonsin ha skrivits ut?
5. Agent-config + `settings.json` på plats (och backup i mounten — efemärt annars)?
6. Historik/state på en **mount**, inte i efemärt fs?
7. Dashboard uppe (check exit 0), tracker live, notiser testade (`kill -9` → ping)?
8. `WAKE.md` + `STOP`-grind + dygnsrytm + nattkörning/nattvakt på plats?
9. Resumbarhet verifierad (resume från checkpoint, inte omstart)?
10. Bönerummet finns för host-kommunikation?

> **Grundregeln bakom allt:** bygg så att ett självkörande team kan jobba en vecka i sträck, tåla
> krascher och omstarter, och aldrig göra något oåterkalleligt mot världen utanför sin bur.
