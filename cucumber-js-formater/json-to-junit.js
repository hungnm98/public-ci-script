/**
 * Convert Cucumber JSON report to JUnit XML format with file attribute
 * This enables CircleCI to rerun failed tests based on file location
 */
const fs = require('fs')
const path = require('path')

function escapeXml(unsafe) {
  return unsafe
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;')
}

function formatDuration(nanoseconds) {
  // Convert nanoseconds to seconds
  return (nanoseconds / 1000000000).toFixed(9)
}

function normalizeFilePath(uri) {
  if (!uri) {
    return ''
  }

  // Keep the original path from JSON - it's already relative to where cucumber runs
  // Example: "../features/quick-sell/quick-sell.feature" stays as "../features/quick-sell/quick-sell.feature"
  // This is correct because cucumber runs from mobile/ directory
  // and features are at ../features/ relative to mobile/

  // Just normalize any double slashes or trailing slashes
  let filePath = uri.replace(/\/+/g, '/').replace(/\/$/, '')

  return filePath
}

function convertJsonToJUnit(jsonFilePath, outputXmlPath) {
  if (!fs.existsSync(jsonFilePath)) {
    console.log(`JSON file not found: ${jsonFilePath}`)
    return true
  }

  const jsonContent = fs.readFileSync(jsonFilePath, 'utf8')
  let features

  try {
    features = JSON.parse(jsonContent)
  } catch (error) {
    console.error(`Error parsing JSON: ${error.message}`)
    return false
  }

  if (!Array.isArray(features)) {
    console.error('JSON format is not an array')
    return false
  }

  let totalTests = 0
  let totalFailures = 0
  let totalSkipped = 0
  let totalTime = 0
  const testcases = []

  // Process each feature
  features.forEach((feature) => {
    const featureName = feature.name || 'Unknown Feature'
    const featureUri = feature.uri || ''
    const filePath = normalizeFilePath(featureUri)

    if (!feature.elements || !Array.isArray(feature.elements)) {
      return
    }

    // Process each scenario
    feature.elements.forEach((element) => {
      if (element.keyword !== 'Scenario' && element.keyword !== 'Scenario Outline') {
        return
      }

      const scenarioName = element.name || 'Unnamed Scenario'
      const scenarioLine = element.line || 0

      // Calculate total duration from steps
      let scenarioDuration = 0
      let scenarioStatus = 'passed'
      let failureMessage = ''
      let failureType = ''
      const stepOutputs = []

      if (element.steps && Array.isArray(element.steps)) {
        element.steps.forEach((step) => {
          // Skip hidden Before/After hooks
          if (step.hidden) {
            return
          }

          if (step.result) {
            const stepDuration = step.result.duration || 0
            scenarioDuration += stepDuration

            const stepKeyword = step.keyword || ''
            const stepName = step.name || ''
            const stepStatus = step.result.status || 'unknown'

            // Build step output line
            const stepLine = `${stepKeyword}${stepName}${'.'.repeat(Math.max(1, 60 - stepName.length - stepKeyword.length))}${stepStatus}`
            stepOutputs.push(stepLine)

            // Check for failures
            if (stepStatus === 'failed') {
              scenarioStatus = 'failed'
              totalFailures++

              if (step.result.error_message) {
                failureMessage = escapeXml(step.result.error_message)
                failureType = 'AssertionError'
              }
            } else if (stepStatus === 'skipped' || stepStatus === 'undefined') {
              // Only mark as skipped if not already failed
              if (scenarioStatus === 'passed') {
                scenarioStatus = 'skipped'
              }
            }
          }
        })
      }

      totalTests++
      totalTime += scenarioDuration

      // Count skipped scenarios
      if (scenarioStatus === 'skipped') {
        totalSkipped++
      }

      // Build testcase XML
      const durationSeconds = formatDuration(scenarioDuration)
      const systemOut = stepOutputs.join('\n')

      let testcaseXml = `    <testcase classname="${escapeXml(featureName)}" name="${escapeXml(scenarioName)}" time="${durationSeconds}" file="${escapeXml(filePath)}">`

      if (scenarioStatus === 'failed') {
        testcaseXml += `\n      <failure type="${escapeXml(failureType)}" message="${escapeXml(failureMessage)}">${escapeXml(failureMessage)}</failure>`
      } else if (scenarioStatus === 'skipped') {
        testcaseXml += `\n      <skipped/>`
      }

      if (systemOut) {
        testcaseXml += `\n      <system-out><![CDATA[${systemOut}]]></system-out>`
      }

      testcaseXml += `\n    </testcase>`
      testcases.push(testcaseXml)
    })
  })

  // Build final JUnit XML
  const totalTimeSeconds = formatDuration(totalTime) // totalTime is already in nanoseconds
  const xml = `<?xml version="1.0"?>
<testsuite failures="${totalFailures}" skipped="${totalSkipped}" name="cucumber-js" time="${totalTimeSeconds}" tests="${totalTests}">
${testcases.join('\n')}
</testsuite>`

  // Ensure output directory exists
  const outputDir = path.dirname(outputXmlPath)
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true })
  }

  // Write XML file
  fs.writeFileSync(outputXmlPath, xml, 'utf8')
  console.log(`✅ Converted JSON to JUnit XML: ${outputXmlPath}`)
  console.log(`   Tests: ${totalTests}, Failures: ${totalFailures}, Skipped: ${totalSkipped}`)

  return true
}

// Run if called directly
if (require.main === module) {
  const jsonFile = process.argv[2] || 'cucumber-report/cucumber.json'
  const xmlFile = process.argv[3] || 'cucumber-report/cucumber.xml'

  const jsonPath = path.isAbsolute(jsonFile)
    ? jsonFile
    : path.join(process.cwd(), jsonFile)

  const xmlPath = path.isAbsolute(xmlFile)
    ? xmlFile
    : path.join(process.cwd(), xmlFile)

  const success = convertJsonToJUnit(jsonPath, xmlPath)
  process.exit(success ? 0 : 1)
}

module.exports = { convertJsonToJUnit }

