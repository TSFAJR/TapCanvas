// Keep historical migration files/checksums intact. A current bootstrap schema
// already omits payment fields that the older baseline repair used to widen.
export function prepareBaselineRepairSql(name, sql) {
  if (name !== '20260715090000_repair_baselined_schema_drift') return sql;
  const normalized = sql.replaceAll('\r\n', '\n');
  const original = `ALTER TABLE "referral_config" ALTER COLUMN "id" SET DEFAULT 1,
ALTER COLUMN "recharge_credits_per_yuan" SET DATA TYPE DOUBLE PRECISION,
ALTER COLUMN "min_recharge_yuan_for_bonus" SET DATA TYPE DOUBLE PRECISION;`;
  if (!normalized.includes(original)) {
    throw new Error('Historical referral repair changed; review its compatibility transformation');
  }
  return normalized.replace(original, `ALTER TABLE "referral_config" ALTER COLUMN "id" SET DEFAULT 1;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'referral_config' AND column_name = 'recharge_credits_per_yuan') THEN
    ALTER TABLE "referral_config" ALTER COLUMN "recharge_credits_per_yuan" SET DATA TYPE DOUBLE PRECISION;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'referral_config' AND column_name = 'min_recharge_yuan_for_bonus') THEN
    ALTER TABLE "referral_config" ALTER COLUMN "min_recharge_yuan_for_bonus" SET DATA TYPE DOUBLE PRECISION;
  END IF;
END $$;`);
}
