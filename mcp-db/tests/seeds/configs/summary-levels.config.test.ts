import {
  describe,
  it,
  expect,
  beforeEach,
  afterEach,
  beforeAll,
  afterAll,
  vi,
} from 'vitest'
import { Client } from 'pg'
import fs from 'fs/promises'
import path from 'path'
import { fileURLToPath } from 'url'

import { dbConfig } from '../../helpers/database-config'
import { GeographyLevel } from '../../../src/schema/geography-level.schema'
import { SeedRunner } from '../../../src/seeds/scripts/seed-runner'
import { seeds } from '../../../src/seeds/scripts/seed-database'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

interface GeographyLevelRow extends GeographyLevel {
  id: number
  parent_summary_level_id: number | null
  created_at: Date
  updated_at: Date
}

describe('Summary Levels Config', () => {
  let runner: SeedRunner
  let client: Client
  let databaseUrl: string

  beforeAll(async () => {
    // Initialize client once for the entire test suite
    client = new Client(dbConfig)
    await client.connect()

    // Construct database URL for SeedRunner
    databaseUrl = `postgresql://${dbConfig.user}:${dbConfig.password}@${dbConfig.host}:${dbConfig.port}/${dbConfig.database}`
  })

  afterAll(async () => {
    await client.end()
  })

  beforeEach(async () => {
    // Create test fixtures directory
    const fixturesPath = path.join(__dirname, 'fixtures')
    try {
      await fs.mkdir(fixturesPath, { recursive: true })
    } catch {
      console.log('Directory already exists.')
    }

    runner = new SeedRunner(databaseUrl, fixturesPath)
    await runner.connect()

    // Clean up summary_levels table before each test and handle deadlocks gracefully
    const cleanupWithRetry = async (maxRetries = 3) => {
      for (let attempt = 1; attempt <= maxRetries; attempt++) {
        try {
          await client.query(
            'TRUNCATE TABLE summary_levels RESTART IDENTITY CASCADE',
          )
          return // Success
        } catch (error: unknown) {
          if (error.code === '40P01' && attempt < maxRetries) {
            // Deadlock detected
            console.log(`Deadlock detected on attempt ${attempt}, retrying...`)
            await new Promise((resolve) => setTimeout(resolve, attempt * 100)) // Exponential backoff
          } else {
            throw error // Re-throw if not a deadlock or max retries exceeded
          }
        }
      }
    }

    await cleanupWithRetry()
  })

  afterEach(async () => {
    await runner.disconnect()
  })

  it('should have valid configuration structure', () => {
    const geographySeed = seeds.find((s) => s.file === 'summary_levels.json')

    expect(geographySeed).toBeDefined()
    expect(geographySeed?.table).toBe('summary_levels')
    expect(geographySeed?.dataPath).toBe('summary_levels')
    expect(geographySeed?.conflictColumn).toBe('code')
    expect(geographySeed?.beforeSeed).toBeDefined()
    expect(geographySeed?.afterSeed).toBeDefined()
  })

  describe('beforeSeed logic', () => {
    it('should validate correct data structure', () => {
      const geographySeed = seeds.find((s) => s.file === 'summary_levels.json')
      expect(geographySeed?.beforeSeed).toBeDefined()

      const validData = [
        {
          name: 'Nation',
          description: 'United States total',
          get_variable: 'NATION',
          query_name: 'us',
          on_spine: true,
          code: '010',
          parent_summary_level: null,
        },
      ]

      // Mock client for validation testing
      const mockClient = {} as Client

      // Should not throw with valid data
      expect(() =>
        geographySeed!.beforeSeed!(mockClient, validData),
      ).not.toThrow()
    })

    it('should reject invalid data structure', () => {
      const geographySeed = seeds.find((s) => s.file === 'summary_levels.json')
      expect(geographySeed?.beforeSeed).toBeDefined()

      const invalidData = [
        {
          name: 'Nation',
          // Missing required fields
          code: '010',
        },
      ]

      const mockClient = {} as Client

      // Should throw with invalid data
      expect(() => geographySeed!.beforeSeed!(mockClient, invalidData)).toThrow(
        /validation failed/i,
      )
    })

    it('should handle empty data array', () => {
      const geographySeed = seeds.find((s) => s.file === 'summary_levels.json')
      expect(geographySeed?.beforeSeed).toBeDefined()

      const emptyData: unknown[] = []
      const mockClient = {} as Client

      // Should handle empty data gracefully
      expect(() =>
        geographySeed!.beforeSeed!(mockClient, emptyData),
      ).not.toThrow()
    })

    it('should provide detailed validation error messages', () => {
      const geographySeed = seeds.find((s) => s.file === 'summary_levels.json')
      expect(geographySeed?.beforeSeed).toBeDefined()

      const invalidData = [
        {
          name: 'Nation',
          description: 'United States total',
          get_variable: 'NATION',
          query_name: 'us',
          on_spine: 'not_boolean', // Invalid type
          code: 123, // Invalid type
          parent_summary_level: null,
        },
      ]

      const mockClient = {} as Client

      try {
        geographySeed!.beforeSeed!(mockClient, invalidData)
        fail('Expected validation to fail')
      } catch (error) {
        expect(error).toBeInstanceOf(Error)
        expect((error as Error).message).toContain('validation failed')
      }
    })
  })

  describe('afterSeed logic', () => {
    beforeEach(async () => {
      // Insert test data first
      await client.query(`
        INSERT INTO summary_levels (name, description, get_variable, query_name, on_spine, code, parent_summary_level)
        VALUES 
          ('Nation', 'United States total', 'NATION', 'us', true, '010', null),
          ('State', 'States and State equivalents', 'STATE', 'state', true, '040', '010'),
          ('County', 'Counties and county equivalents', 'COUNTY', 'county', true, '050', '040')
      `)
    })

    it('should establish parent relationships correctly', async () => {
      const geographySeed = seeds.find((s) => s.file === 'summary_levels.json')
      expect(geographySeed?.afterSeed).toBeDefined()

      // Run the afterSeed logic
      await geographySeed!.afterSeed!(client)

      // Verify relationships were established
      const result = await client.query<{
        name: string
        code: string
        parent_name: string | null
        parent_summary_level: string | null
      }>(`
        SELECT 
          g.name,
          g.code,
          p.name as parent_name,
          g.parent_summary_level
        FROM summary_levels g
        LEFT JOIN summary_levels p ON g.parent_summary_level_id = p.id
        ORDER BY g.code
      `)

      expect(result.rows).toHaveLength(3)

      const nation = result.rows.find((row) => row.code === '010')
      const state = result.rows.find((row) => row.code === '040')
      const county = result.rows.find((row) => row.code === '050')

      expect(nation?.parent_name).toBeNull()
      expect(state?.parent_name).toBe('Nation')
      expect(county?.parent_name).toBe('State')
    })

    it('should handle missing parent references gracefully', async () => {
      // Add a record with non-existent parent
      await client.query(`
        INSERT INTO summary_levels (name, description, get_variable, query_name, on_spine, code, parent_summary_level)
        VALUES ('Orphan', 'Orphaned level', 'ORPHAN', 'orphan', true, '999', '888')
      `)

      const geographySeed = seeds.find((s) => s.file === 'summary_levels.json')
      expect(geographySeed?.afterSeed).toBeDefined()

      // Should not throw
      await expect(geographySeed!.afterSeed!(client)).resolves.not.toThrow()

      // Verify orphan has null parent_summary_level_id
      const orphanResult = await client.query(`
        SELECT parent_summary_level_id 
        FROM summary_levels 
        WHERE code = '999'
      `)

      expect(orphanResult.rows[0].parent_summary_level_id).toBeNull()
    })

    it('should log relationship statistics', async () => {
      const geographySeed = seeds.find((s) => s.file === 'summary_levels.json')
      expect(geographySeed?.afterSeed).toBeDefined()

      // Capture console output
      const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {})
      const consoleWarnSpy = vi
        .spyOn(console, 'warn')
        .mockImplementation(() => {})

      try {
        await geographySeed!.afterSeed!(client)

        // Should log relationship statistics
        expect(consoleSpy).toHaveBeenCalledWith(
          expect.stringContaining(
            'Geography levels: 3 total, 2/2 with parents',
          ),
        )

        // Should not warn about orphans (all parents exist)
        expect(consoleWarnSpy).not.toHaveBeenCalledWith(
          expect.stringContaining('Orphaned records'),
        )
      } finally {
        consoleSpy.mockRestore()
        consoleWarnSpy.mockRestore()
      }
    })

    it('should warn about orphaned records when parents are missing', async () => {
      // Add orphaned records
      await client.query(`
        INSERT INTO summary_levels (name, description, get_variable, query_name, on_spine, code, parent_summary_level)
        VALUES 
          ('Orphan1', 'First orphan', 'ORPHAN1', 'orphan1', true, '888', '777'),
          ('Orphan2', 'Second orphan', 'ORPHAN2', 'orphan2', true, '999', '777')
      `)

      const geographySeed = seeds.find((s) => s.file === 'summary_levels.json')
      expect(geographySeed?.afterSeed).toBeDefined()

      const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {})
      const consoleWarnSpy = vi
        .spyOn(console, 'warn')
        .mockImplementation(() => {})

      try {
        await geographySeed!.afterSeed!(client)

        // Should warn about orphaned records
        expect(consoleWarnSpy).toHaveBeenCalledWith(
          'Orphaned records:',
          expect.arrayContaining([
            expect.objectContaining({
              name: 'Orphan1',
              code: '888',
            }),
            expect.objectContaining({
              name: 'Orphan2',
              code: '999',
            }),
          ]),
        )
      } finally {
        consoleSpy.mockRestore()
        consoleWarnSpy.mockRestore()
      }
    })
  })

  // Integration tests for the complete seed workflow
  describe('complete seed workflow', () => {
    it('should seed geography levels with parent relationships', async () => {
      // Create test geography levels data
      const testGeographyData = {
        summary_levels: [
          {
            name: 'Nation',
            description: 'United States total',
            get_variable: 'NATION',
            query_name: 'us',
            on_spine: true,
            code: '010',
            parent_summary_level: null,
          },
          {
            name: 'State',
            description: 'States and State equivalents',
            get_variable: 'STATE',
            query_name: 'state',
            on_spine: true,
            code: '040',
            parent_summary_level: '010',
          },
          {
            name: 'County',
            description: 'Counties and county equivalents',
            get_variable: 'COUNTY',
            query_name: 'county',
            on_spine: true,
            code: '050',
            parent_summary_level: '040',
          },
        ],
      }

      const filePath = path.join(__dirname, 'fixtures', 'summary_levels.json')
      await fs.writeFile(filePath, JSON.stringify(testGeographyData))

      // Run the seed with the simplified configuration
      const seedConfig = {
        file: 'summary_levels.json',
        table: 'summary_levels',
        conflictColumn: 'code',
        dataPath: 'summary_levels',
        beforeSeed: async (client: Client) => {
          // Create indexes
          await client.query(`
            CREATE INDEX IF NOT EXISTS idx_summary_levels_summary_level 
            ON summary_levels(code);
          `)

          await client.query(`
            CREATE INDEX IF NOT EXISTS idx_summary_levels_parent_summary_level 
            ON summary_levels(parent_summary_level);
          `)
        },
        afterSeed: async (client: Client) => {
          // Update parent relationships
          await client.query(`
            UPDATE summary_levels 
            SET parent_summary_level_id = (
              SELECT id 
              FROM summary_levels parent 
              WHERE parent.code = summary_levels.parent_summary_level
            )
            WHERE parent_summary_level IS NOT NULL;
          `)
        },
      }

      await runner.seed(seedConfig)

      // Verify data was inserted
      const result = await client.query<GeographyLevelRow>(
        'SELECT * FROM summary_levels ORDER BY code',
      )
      expect(result.rows).toHaveLength(3)

      // Verify specific records
      const nation = result.rows.find((row) => row.code === '010')
      const state = result.rows.find((row) => row.code === '040')
      const county = result.rows.find((row) => row.code === '050')

      expect(nation?.name).toBe('Nation')
      expect(nation?.parent_summary_level_id).toBeNull()

      expect(state?.name).toBe('State')
      expect(state?.parent_summary_level_id).toBe(nation?.id)

      expect(county?.name).toBe('County')
      expect(county?.parent_summary_level_id).toBe(state?.id)
    })

    it('should handle idempotent seeding (skip existing records)', async () => {
      // Create test data
      const testGeographyData = {
        summary_levels: [
          {
            name: 'Nation',
            description: 'United States total',
            get_variable: 'NATION',
            query_name: 'us',
            on_spine: true,
            code: '010',
            parent_summary_level: null,
          },
          {
            name: 'State',
            description: 'States and State equivalents',
            get_variable: 'STATE',
            query_name: 'state',
            on_spine: true,
            code: '040',
            parent_summary_level: '010',
          },
        ],
      }

      const filePath = path.join(
        __dirname,
        'fixtures',
        'summary_levels_idempotent.json',
      )
      await fs.writeFile(filePath, JSON.stringify(testGeographyData))

      const seedConfig = {
        file: 'summary_levels_idempotent.json',
        table: 'summary_levels',
        conflictColumn: 'code',
        dataPath: 'summary_levels',
        afterSeed: async (client: Client) => {
          // Update parent relationships
          await client.query(`
            UPDATE summary_levels 
            SET parent_summary_level_id = (
              SELECT id 
              FROM summary_levels parent 
              WHERE parent.code = summary_levels.parent_summary_level
            )
            WHERE parent_summary_level IS NOT NULL;
          `)
        },
      }

      // Run seed twice
      await runner.seed(seedConfig)
      await runner.seed(seedConfig)

      // Should still have only 2 records (not duplicated)
      const result = await client.query<GeographyLevelRow>(
        'SELECT * FROM summary_levels ORDER BY code',
      )
      expect(result.rows).toHaveLength(2)

      // Verify the records are correct
      const nation = result.rows.find((row) => row.code === '010')
      const state = result.rows.find((row) => row.code === '040')

      expect(nation?.name).toBe('Nation')
      expect(state?.name).toBe('State')
      expect(state?.parent_summary_level_id).toBe(nation?.id)
    })
  })
})
