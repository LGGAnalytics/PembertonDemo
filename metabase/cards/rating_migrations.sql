-- Rating migrations this month (latest month vs previous month-end; spec 004)
SELECT borrower_name                                                    AS "Borrower",
       fund_code                                                        AS "Fund",
       agency_changed                                                   AS "Agency",
       coalesce(committee_from, '–') || ' → ' || coalesce(committee_to, '–') AS "Committee",
       coalesce(sp_from, '–')        || ' → ' || coalesce(sp_to, '–')        AS "S&P",
       coalesce(moodys_from, '–')    || ' → ' || coalesce(moodys_to, '–')    AS "Moody's",
       coalesce(score_from::TEXT, '–') || ' → ' || coalesce(score_to::TEXT, '–') AS "Score",
       round(outstanding_eur / 1e6, 1)                                  AS "Outstanding (EUR m)"
FROM bi.vw_rating_migration
WHERE is_migration
  AND as_of_date = (SELECT max(as_of_date) FROM bi.vw_rating_migration)
  [[AND fund_code = {{fund}}]]
ORDER BY score_to DESC NULLS LAST, outstanding_eur DESC
