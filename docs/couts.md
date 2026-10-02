# Coûts indicatifs

Ordres de grandeur pour décider, pas un devis. Les tarifs ci-dessous sont les grilles publiques de
Railway et de Cloudflare telles que connues en septembre 2026 ; ils n'ont pas pu être revérifiés
depuis l'environnement de développement (aucun accès réseau à ces services). **Les revérifier sur
les pages de tarifs avant d'engager une dépense.** Montants en dollars US, hors taxes.

## Railway

Facturation à l'usage, avec un abonnement qui inclut un crédit d'usage du même montant.

| Poste                    | Tarif                         |
| ------------------------ | ----------------------------- |
| Plan Pro                 | 20 $/mois par siège, 20 $ d'usage inclus (IP de sortie statiques, réplicas) |
| Mémoire                  | ~10 $ par Go-mois             |
| vCPU                     | ~20 $ par vCPU-mois           |
| Volume (PostgreSQL)      | ~0,15 $ par Go-mois           |
| Sortie réseau            | ~0,05 $ par Go                |

Hypothèse de lancement (charge faible, un réplica par service) :

| Service    | Mémoire moyenne | CPU moyen |
| ---------- | --------------- | --------- |
| web        | 0,4 Go          | 0,05      |
| admin      | 0,2 Go          | 0,01      |
| api        | 0,4 Go          | 0,05      |
| realtime   | 0,3 Go          | 0,05      |
| PostgreSQL | 0,5 Go, volume 5 Go | 0,05  |
| Redis      | 0,1 Go          | 0,01      |
| backup     | quelques minutes par jour | négligeable |

Soit ~1,9 Go × 10 $ + 0,22 vCPU × 20 $ + 5 Go × 0,15 $ ≈ **25 $/mois d'usage**, couverts en
grande partie par les 20 $ du plan Pro : **~25 à 30 $/mois**. Le plan Hobby (5 $) suffit pour un
essai, sans IP de sortie statiques.

## Cloudflare

| Poste                      | Tarif                                                        |
| -------------------------- | ------------------------------------------------------------ |
| Zone, plan Free            | 0 $ (une règle de limitation de débit, WAF personnalisé de base) |
| Zone, plan Pro (option)    | ~20 à 25 $/mois (Managed Ruleset complet, deux règles de débit) |
| Workers Paid               | 5 $/mois, inclut 10 M de requêtes ; requis pour Containers et Durable Objects |
| Containers                 | inclus : ~25 Go-h de mémoire, ~375 vCPU-min, ~200 Go-h de disque par mois ; au-delà ~0,0000025 $/Gio-s de mémoire, ~0,00002 $/vCPU-s |
| Durable Objects            | quasi nul à cette échelle (un objet par projet actif)        |
| R2 stockage                | 0,015 $/Go-mois (10 Go gratuits)                             |
| R2 opérations              | classe A 4,50 $/M, classe B 0,36 $/M (1 M et 10 M gratuits)  |
| R2 sortie                  | 0 $                                                          |

### Compilations

Le coût dominant est la mémoire des conteneurs **éveillés** : une instance reste allumée ~15 min
après la dernière activité. Le Worker de kaxolax-platform utilise le type `standard-4` (4 vCPU,
12 Gio, disque assez grand pour TeX Live complet) : 12 Gio × 3 600 s × 0,0000025 $ ≈ **0,11 $ par
heure éveillée**, plus le CPU réellement consommé pendant les compilations.

| Usage                                         | Heures éveillées / mois | Coût mémoire |
| --------------------------------------------- | ----------------------- | ------------ |
| 20 projets actifs, 1 h d'édition par jour      | ~600 h                  | ~65 $        |
| 100 projets actifs, 1 h d'édition par jour     | ~3 000 h                | ~325 $       |

Leviers : type d'instance plus petit (image TeX Live réduite, plan gratuit), délai de mise en veille plus court,
réveil anticipé seulement à l'ouverture de l'éditeur (pas du tableau de bord).

### Stockage

50 Go de fichiers de projets, PDF et sauvegardes : ~0,60 $/mois. Les sauvegardes (35 jours de
rétention) pèsent ~35 × la taille d'un dump compressé.

## Total au lancement

| Poste                         | Mois         |
| ----------------------------- | ------------ |
| Railway (Pro)                 | ~25 à 30 $   |
| Cloudflare Workers Paid       | 5 $          |
| Conteneurs de compilation     | ~65 à 325 $ selon l'activité |
| R2                            | ~1 $         |
| Zone Cloudflare               | 0 $ (Free) ou ~20 $ (Pro) |
| **Total**                     | **~95 à 385 $/mois** |

À comparer au staging AWS de l'étape 1 (~200 $/mois pour un seul environnement sans haute
disponibilité) : la compilation n'est plus payée quand personne n'édite, mais elle devient le
premier poste dès que l'activité monte ; le délai de mise en veille et le type d'instance sont les
deux réglages à surveiller.
