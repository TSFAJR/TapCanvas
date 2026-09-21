import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { prepareBaselineRepairSql } from './baseline-repair-sql.mjs';

test('guards retired columns in the real historical repair without changing unrelated DDL', () => {
  const name = '20260715090000_repair_baselined_schema_drift';
  const sql = readFileSync(new URL(`../prisma/migrations/${name}/migration.sql`, import.meta.url), 'utf8').replaceAll('\r\n', '\n');
  const repaired = prepareBaselineRepairSql(name, sql);
  assert.equal((repaired.match(/IF EXISTS \(SELECT 1 FROM information_schema.columns/g) || []).length, 2);
  assert.ok(repaired.includes('ALTER COLUMN "id" SET DEFAULT 1;'));
  assert.equal(repaired.slice(repaired.indexOf('-- CreateTable')), sql.slice(sql.indexOf('-- CreateTable')));
  assert.equal(prepareBaselineRepairSql('unrelated', sql), sql);
  assert.equal(prepareBaselineRepairSql(name, sql.replaceAll('\n', '\r\n')), repaired);
  assert.throws(() => prepareBaselineRepairSql(name, 'SELECT 1;'), /review its compatibility/);
});
