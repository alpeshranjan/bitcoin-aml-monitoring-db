# Data Source Summary

**ANLC-752 — Unit 1, Course Project Planning**
Structuring transaction-level Bitcoin blockchain data in an RDBMS to support identification and monitoring of transaction patterns associated with illicit activity.

---

## 1. Dataset

**The Elliptic Data Set** — a graph of real but anonymised Bitcoin transactions released by Elliptic Ltd., a blockchain analytics and compliance firm, in collaboration with the MIT-IBM Watson AI Lab. Each node is a Bitcoin transaction; each directed edge is a flow of bitcoin from one transaction to another. A subset of nodes carries a ground-truth licit/illicit label derived from Elliptic's own entity attribution process.

| Property | Value |
|---|---|
| Transactions (nodes) | 203,769 |
| Directed money-flow edges | 234,355 |
| Time steps | 49 (≈ 2 weeks each, evenly spaced) |
| Node features | 166 (time step + 93 local + 72 aggregate) |
| Labelled illicit (class 1) | 4,545 (2.23%) |
| Labelled licit (class 2) | 42,019 (20.62%) |
| Unlabelled (class 3) | 157,205 (77.15%) |
| Total labelled | 46,564 (22.85%) |

The class distribution above was verified directly against `elliptic_txs_classes.csv` rather than taken from the literature; the counts reproduce those reported in the source papers exactly.

**Files.** Three CSVs. `elliptic_txs_classes.csv` (txId, class), `elliptic_txs_edgelist.csv` (txId1, txId2), and `elliptic_txs_features.csv` (167 columns: txId, time step, 165 feature values, **no header row**).

**Access.** Distributed publicly on Kaggle. The licence stated on the dataset page governs
permitted use; its non-commercial and share-alike style terms are satisfied by academic
coursework, and the loaded database is not redistributed as a derivative work.

---

## 2. Origin and credibility

The data was not scraped, crowdsourced, or self-reported. Three properties support its use as an evidentiary basis:

**Institutional provenance.** Elliptic Ltd. is an established blockchain analytics firm whose commercial product is exactly this kind of attribution, sold to exchanges and financial institutions for regulatory compliance. The labels are a by-product of a process the firm is paid to get right.

**Peer review.** The dataset was introduced in a tutorial at the Anomaly Detection in Finance Workshop at KDD 2019 (Weber et al., 2019). It was subsequently extended and independently re-validated in a full peer-reviewed KDD 2023 paper (Elmougy & Liu, 2023). It is now a standard benchmark in the financial-forensics literature, which means both its strengths and its defects have been examined by parties with no stake in it.

**Label methodology.** Classification is applied at the level of the *entity* that controls a transaction, using Elliptic's heuristics-based attribution. Illicit covers scams, malware, ransomware, Ponzi schemes and terrorist organisations; licit covers exchanges, wallet providers, miners and licensed financial providers. Labels are not derived from the transaction features themselves, so feature-based analysis is not circular.

---

## 3. Completeness

The core fields required by this project — transaction identifier, time step, class label, and edge endpoints — are fully populated. There are no missing values in the feature matrix, no duplicate transaction identifiers, and every edge endpoint resolves to a node present in the node set. These are not assumptions: each is enforced as a named data quality rule in the load pipeline (§5) and each passed on the full 203,769-row extract.

Two genuine gaps, both scoped rather than concealed:

- **77% of transactions are unlabelled.** These are not negative examples; a class-3 transaction is one whose controlling entity Elliptic could not attribute. Supervised evaluation is therefore confined to the 46,564 labelled transactions. The unlabelled majority is still loaded and still carries money flow, because excluding it would sever the graph — an unlabelled transaction sitting between two illicit ones is precisely the object a layering typology needs to see. The schema encodes this distinction structurally: `core.dim_class.is_labelled` is a separate boolean from the class code, so an analyst cannot silently treat "unknown" as "licit."
- **Class imbalance is severe.** At 2.23% illicit, accuracy is a meaningless metric and any threshold-based rule needs to be evaluated on precision and recall at a fixed review budget.

---

## 4. Relevance to the project objectives

The research question is one of *data management*, not model performance: how should this data be structured so that AML pattern monitoring is efficiently expressible? The dataset fits that question for four reasons.

1. **It is genuinely relational.** Nodes, directed edges, a wide attribute vector, and a classification outcome map onto entities, relationships, and dimensions without contortion.
2. **The graph is the point.** Money laundering is defined by movement — placement, layering, integration. A dataset of isolated transactions could not express those typologies. The edge table is what makes recursive provenance tracing and one-hop exposure scoring possible in SQL.
3. **It has a real time axis.** Forty-nine ordered periods support temporal partitioning, period-over-period risk profiling, and a realistic train/test split by time rather than at random.
4. **The scale is right for the exercise.** Large enough that indexing strategy, bulk-load method and join order have measurable consequences; small enough to run on a single PostgreSQL instance without a distributed cluster. The loaded database is 367 MB as originally measured, and 471 MB after the partitioning migration, which trades storage for period-scoped query pruning.

---

## 5. Limitations

**Features are obfuscated.** The 165 feature values are anonymised and cannot be mapped to real-world attributes such as transaction value, fee, or output count. Analytical findings can therefore be expressed as "feature 53 separates the classes," never as "large transactions are riskier." That example is no longer hypothetical: the screening in `sql/04_analysis.sql` finds `local_feature_53` to be the single strongest separator of the two labelled classes (Cohen's d = -0.913), and that sentence is the most that can be said about it. This constrains interpretability and rules out any rule expressed in business terms. It does not affect the data management objectives — schema design, ETL, and governance are unchanged by whether a numeric column has a human-readable name — and the schema records the constraint explicitly in `core.dim_feature.is_obfuscated`.

**Edges are transaction-to-transaction, not party-to-party.** This is the constraint most likely to mislead. The dataset contains no wallets, accounts, or counterparties, so no customer or entity dimension can be built from it, and a predicted-illicit transaction cannot be attributed to a responsible address. Elmougy and Liu identify this as the original dataset's principal shortcoming and address it in Elliptic++ by adding an 822k-address actor layer. Adding that layer is the natural extension of this project's schema and is noted as future scope, not present scope.

**Labels are binary, without typology.** Class 1 aggregates scams, ransomware, Ponzi schemes and terrorist financing into a single "illicit" value. Money laundering specifically cannot be separated from other illicit categories. Findings must therefore be stated in terms of illicit activity generally.

**The data is historical.** It reflects a fixed window of Bitcoin activity captured before 2019. Laundering typologies have since shifted toward mixers, cross-chain bridges and privacy coins, so the dataset supports methodological conclusions about database design rather than claims about present-day threat patterns.

---

## 6. References

Elliptic Ltd. (2019). *Elliptic Data Set* [Data set]. Kaggle. https://www.kaggle.com/datasets/ellipticco/elliptic-data-set

Elmougy, Y., & Liu, L. (2023). Demystifying fraudulent transactions and illicit nodes in the Bitcoin network for financial forensics. In *Proceedings of the 29th ACM SIGKDD Conference on Knowledge Discovery and Data Mining* (KDD '23) (pp. 3979–3990). Association for Computing Machinery. https://doi.org/10.1145/3580305.3599803

Weber, M., Domeniconi, G., Chen, J., Weidele, D. K. I., Bellei, C., Robinson, T., & Leiserson, C. E. (2019). *Anti-money laundering in Bitcoin: Experimenting with graph convolutional networks for financial forensics*. KDD Workshop on Anomaly Detection in Finance. arXiv. https://arxiv.org/abs/1908.02591
