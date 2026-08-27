# -*- coding: utf-8 -*-
"""로지스틱 회귀 — M1~M4 (RQ1, RQ2).

    M1 = A (금융, 18)          베이스라인
    M2 = B (전통 비금융, 31)    비금융 단독
    M3 = A + B (49)            RQ1: 비금융이 금융에 기여하는가?   → M3 vs M1
    M4 = A + B + C (64)        RQ2: 신규 비금융이 추가 기여하는가? → M4 vs M3

판정: DeLong p < 0.05 (통계) AND ΔAUC ≥ 1%p (실무).
실행: 같은 폴더에 CSV 3개를 두고  python logistic_regression.py
설계: EXT_SOURCE 제외 · 스케일링은 폴드 내부에서만 fit(누수 차단) · class_weight='balanced'
      · 학력/주거 원핫 더미트랩은 계수 해석용으로 기준범주 자동 제거.
"""
import numpy as np
import pandas as pd
import scipy.linalg
from scipy import stats
from sklearn.model_selection import StratifiedKFold
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import Pipeline
from sklearn.metrics import roc_auc_score
import statsmodels.api as sm

# ============================== 설정 ==============================
PATH_A = "model_A_financial_final.csv"
PATH_B = "model_B_nonfinancial_final.csv"
PATH_C = "model_C_nonfinancial_new_final.csv"
N_BOOT = 1000
ID_COL, TARGET = "SK_ID_CURR", "TARGET"


# =============== DeLong 검정 + 부트스트랩 신뢰구간 ===============
def _compute_midrank(x):
    order = np.argsort(x); ranked = x[order]; n = len(x)
    out_sorted = np.zeros(n, dtype=float); i = 0
    while i < n:
        j = i
        while j < n and ranked[j] == ranked[i]:
            j += 1
        out_sorted[i:j] = 0.5 * (i + j - 1) + 1.0
        i = j
    out = np.empty(n, dtype=float); out[order] = out_sorted
    return out


def _fast_delong(preds_sorted, n_pos):
    n_total = preds_sorted.shape[1]; n_neg = n_total - n_pos; k = preds_sorted.shape[0]
    pos, neg = preds_sorted[:, :n_pos], preds_sorted[:, n_pos:]
    tx = np.empty([k, n_pos]); ty = np.empty([k, n_neg]); tz = np.empty([k, n_total])
    for r in range(k):
        tx[r] = _compute_midrank(pos[r]); ty[r] = _compute_midrank(neg[r]); tz[r] = _compute_midrank(preds_sorted[r])
    aucs = tz[:, :n_pos].sum(axis=1) / n_pos / n_neg - (n_pos + 1.0) / 2.0 / n_neg
    v01 = (tz[:, :n_pos] - tx) / n_neg
    v10 = 1.0 - (tz[:, n_pos:] - ty) / n_pos
    cov = np.cov(v01) / n_pos + np.cov(v10) / n_neg
    return aucs, np.atleast_2d(cov)


def delong_test(y_true, score_full, score_reduced):
    """상관 AUC 차이 검정. Returns (ΔAUC, z, p). AUC는 roc_auc_score와 일치 검증됨."""
    y = np.asarray(y_true, dtype=float)
    order = (-y).argsort(kind="mergesort"); n_pos = int(y.sum())
    preds = np.vstack((np.asarray(score_full)[order], np.asarray(score_reduced)[order]))
    aucs, cov = _fast_delong(preds, n_pos)
    var = (np.array([[1.0, -1.0]]) @ cov @ np.array([[1.0], [-1.0]])).item()
    delta = aucs[0] - aucs[1]
    if var <= 0:
        return delta, 0.0, 1.0
    z = delta / np.sqrt(var)
    return delta, z, 2 * (1 - stats.norm.cdf(abs(z)))


def _strat_idx(y, rng):
    pos = np.where(y == 1)[0]; neg = np.where(y == 0)[0]
    return np.concatenate([rng.choice(pos, pos.size, True), rng.choice(neg, neg.size, True)])


def bootstrap_auc_ci(y, s, n_boot=N_BOOT, seed=42):
    rng = np.random.default_rng(seed); y = np.asarray(y); s = np.asarray(s)
    out = np.array([roc_auc_score(y[i := _strat_idx(y, rng)], s[i]) for _ in range(n_boot)])
    return tuple(np.percentile(out, [2.5, 97.5]))


def bootstrap_diff_ci(y, sf, sr, n_boot=N_BOOT, seed=42):
    rng = np.random.default_rng(seed); y = np.asarray(y); sf = np.asarray(sf); sr = np.asarray(sr)
    out = np.empty(n_boot)
    for k in range(n_boot):
        i = _strat_idx(y, rng); out[k] = roc_auc_score(y[i], sf[i]) - roc_auc_score(y[i], sr[i])
    return tuple(np.percentile(out, [2.5, 97.5]))


# =============== 데이터 로딩 · OOF 로지스틱 · 계수 ===============
def _clean(df):
    nonnum = [c for c in df.columns if not pd.api.types.is_numeric_dtype(df[c])]  # AGE_BAND 등 제외
    if nonnum:
        print(f"  [clean] 비숫자 컬럼 제외: {nonnum}")
    df = df.drop(columns=nonnum)
    for c in df.columns:
        if df[c].dtype == bool:
            df[c] = df[c].astype(int)
    return df


def load_and_merge(path_a, path_b, path_c):
    a = _clean(pd.read_csv(path_a)); b = _clean(pd.read_csv(path_b)); c = _clean(pd.read_csv(path_c))
    m = a.merge(b.drop(columns=[TARGET]), on=ID_COL).merge(c.drop(columns=[TARGET]), on=ID_COL)
    groups = {"A": [x for x in a.columns if x not in (ID_COL, TARGET)],
              "B": [x for x in b.columns if x not in (ID_COL, TARGET)],
              "C": [x for x in c.columns if x not in (ID_COL, TARGET)]}
    return m, m[TARGET].astype(int).values, groups


def oof_logistic(m, y, cols, n_splits=5, seed=42, C=1.0):
    """누수 차단 5-fold OOF 로지스틱. 스케일링은 각 폴드 train으로만 fit."""
    X = m[cols].values.astype(float)
    skf = StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=seed)
    oof = np.zeros(len(m))
    for tr, te in skf.split(X, y):
        pipe = Pipeline([("scaler", StandardScaler()),
                         ("lr", LogisticRegression(C=C, max_iter=2000, class_weight="balanced", solver="lbfgs"))])
        pipe.fit(X[tr], y[tr]); oof[te] = pipe.predict_proba(X[te])[:, 1]
    return oof


def _drop_collinear(m, cols, tol=1e-9):
    X = m[cols].values.astype(float)
    Xs = np.column_stack([np.ones(len(X)), (X - X.mean(0)) / (X.std(0) + 1e-12)])
    _, r, piv = scipy.linalg.qr(Xs, mode="economic", pivoting=True)
    diag = np.abs(np.diag(r)); rank = int((diag > tol * diag[0]).sum())
    keep = [cols[i - 1] for i in sorted(piv[:rank]) if i >= 1]
    dropped = [cols[i - 1] for i in piv[rank:] if i >= 1]
    return keep, dropped


def coef_table(m, y, cols, groups):
    """로지스틱 계수·오즈비·p값·VIF (연속형 표준화, 더미트랩 처리). |z| 내림차순."""
    col2group = {c: g for g, cs in groups.items() for c in cs}
    keep, dropped = _drop_collinear(m, list(cols))
    if dropped:
        print(f"  [coef] 더미트랩 기준범주 제거: {dropped}")
    binary = [c for c in keep if m[c].nunique() <= 2]
    Xstd = m[keep].astype(float).copy()
    for c in keep:
        if c not in binary and Xstd[c].std() > 0:
            Xstd[c] = (Xstd[c] - Xstd[c].mean()) / Xstd[c].std()
    base = m[keep].astype(float)
    vif = pd.Series(np.diag(np.linalg.pinv(np.corrcoef(((base - base.mean()) / base.std()).values, rowvar=False))), index=keep)
    res = sm.Logit(y, sm.add_constant(Xstd)).fit(method="newton", maxiter=100, disp=0)
    star = lambda p: "***" if p < .001 else "**" if p < .01 else "*" if p < .05 else ""
    tab = pd.DataFrame({
        "variable": res.params.index, "group": [col2group.get(c, "const") for c in res.params.index],
        "coef": res.params.values, "odds_ratio": np.exp(res.params.values),
        "p_value": res.pvalues.values, "sig": [star(p) for p in res.pvalues.values],
        "VIF": [vif.get(c, np.nan) for c in res.params.index]}).iloc[1:].reset_index(drop=True)
    tab["_absz"] = (tab["coef"] / res.bse.values[1:]).abs()
    return tab.sort_values("_absz", ascending=False).drop(columns="_absz").reset_index(drop=True)


# ============================== 실행 ==============================
def main():
    m, y, groups = load_and_merge(PATH_A, PATH_B, PATH_C)
    A, B, C = groups["A"], groups["B"], groups["C"]
    print(f"rows={len(m):,}  A={len(A)}  B={len(B)}  C={len(C)}  연체율={y.mean():.4f}")

    # M1~M4 OOF 로지스틱
    specs = {"M1": A, "M2": B, "M3": A + B, "M4": A + B + C}
    oof = {k: oof_logistic(m, y, cols) for k, cols in specs.items()}
    auc = {k: roc_auc_score(y, v) for k, v in oof.items()}
    ci = {k: bootstrap_auc_ci(y, v) for k, v in oof.items()}
    model_tbl = pd.DataFrame([
        {"model": k, "X": x, "n_features": len(specs[k]), "OOF_AUC": round(auc[k], 4),
         "CI_low": round(ci[k][0], 4), "CI_high": round(ci[k][1], 4)}
        for k, x in [("M1", "A"), ("M2", "B"), ("M3", "A+B"), ("M4", "A+B+C")]])
    print(model_tbl.to_string(index=False))

    # RQ 검정 (DeLong + 부트스트랩)
    def compare(tag, full, reduced):
        d, z, p = delong_test(y, oof[full], oof[reduced])
        lo, hi = bootstrap_diff_ci(y, oof[full], oof[reduced])
        return {"검정": tag, "비교": f"{full} vs {reduced}", "dAUC(%p)": round(d * 100, 3),
                "DeLong_z": round(z, 2), "DeLong_p": f"{p:.2e}", "CI(%p)": f"[{lo*100:.2f}, {hi*100:.2f}]",
                "판정": "통과" if (p < 0.05 and d >= 0.01) else "미달"}

    rq = pd.DataFrame([compare("RQ1 (B 기여)", "M3", "M1"),
                       compare("RQ2 (신규 C 순증)", "M4", "M3"),
                       compare("참고: 비금융 전체", "M4", "M1")])
    print(rq.to_string(index=False))

    # M4 계수·VIF
    coef = coef_table(m, y, A + B + C, groups)

    # 저장
    with pd.ExcelWriter("logistic_results.xlsx", engine="openpyxl") as xw:
        model_tbl.to_excel(xw, sheet_name="01_모델비교", index=False)
        rq.to_excel(xw, sheet_name="02_연구질문검정", index=False)
        coef.assign(p_value=coef.p_value.map(lambda v: f"{v:.2e}")).to_excel(xw, sheet_name="03_M4계수", index=False)
    pd.DataFrame({"SK_ID_CURR": m["SK_ID_CURR"], **{f"oof_{k}": v for k, v in oof.items()}, "TARGET": y}) \
        .to_csv("oof_M1_M4.csv", index=False)
    print("저장: logistic_results.xlsx, oof_M1_M4.csv")


if __name__ == "__main__":
    main()
