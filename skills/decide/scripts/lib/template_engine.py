"""Template engine for decision configurator.

Injects config JSON into wizard.html template by replacing the /* __CONFIG__ */ placeholder.

@decision DEC-DECIDE-001
@title String-based template injection for single-file HTML output
@status accepted
@rationale No build tools or dependencies required. Config injected as JavaScript
object literal via simple string replacement. Template remains readable HTML.
Alternative approaches (Jinja2, template literals) would add dependencies or
complicate the output. Single-file HTML works offline and is trivially shareable.
"""

import json
import re


def inject_config(template_content: str, config: dict) -> str:
    """Inject config object into template.

    Args:
        template_content: HTML template content with /* __CONFIG__ */ placeholder
        config: Configuration dictionary

    Returns:
        HTML with config injected as JavaScript object literal

    Raises:
        ValueError: If placeholder not found in template
    """
    placeholder = r'/\*\s*__CONFIG__\s*\*/'

    if not re.search(placeholder, template_content):
        raise ValueError(
            "Template missing /* __CONFIG__ */ placeholder. "
            "Expected format: const CONFIG = /* __CONFIG__ */;"
        )

    # Convert config to JSON with proper escaping for JavaScript
    config_json = json.dumps(config, indent=2, ensure_ascii=False)

    # Escape for safe embedding in JavaScript
    # JSON.stringify already handles most escaping, but we need to be careful with </script>
    config_json = config_json.replace('</script>', r'<\/script>')

    # Replace placeholder
    result = re.sub(placeholder, config_json, template_content)

    return result


def validate_config(config: dict) -> list[str]:
    """Validate config has required fields.

    Args:
        config: Configuration dictionary

    Returns:
        List of validation error messages (empty if valid)
    """
    errors = []

    # Check meta
    if 'meta' not in config:
        errors.append("Missing required field: meta")
    else:
        if 'title' not in config['meta']:
            errors.append("Missing required field: meta.title")
        if 'type' not in config['meta']:
            errors.append("Missing required field: meta.type")
        elif config['meta']['type'] not in ['purchase', 'technical', 'implementation', 'configuration']:
            errors.append(
                f"Invalid meta.type: {config['meta']['type']}. "
                "Must be one of: purchase, technical, implementation, configuration"
            )

    # Check steps
    if 'steps' not in config:
        errors.append("Missing required field: steps")
    elif not isinstance(config['steps'], list):
        errors.append("Field 'steps' must be an array")
    elif len(config['steps']) == 0:
        errors.append("Field 'steps' must have at least one step")
    else:
        for i, step in enumerate(config['steps']):
            if 'id' not in step:
                errors.append(f"Step {i}: missing required field 'id'")
            if 'title' not in step:
                errors.append(f"Step {i}: missing required field 'title'")
            if 'options' not in step:
                errors.append(f"Step {i}: missing required field 'options'")
            elif not isinstance(step['options'], list):
                errors.append(f"Step {i}: field 'options' must be an array")
            elif len(step['options']) == 0:
                errors.append(f"Step {i}: field 'options' must have at least one option")
            else:
                for j, option in enumerate(step['options']):
                    if 'id' not in option:
                        errors.append(f"Step {i}, option {j}: missing required field 'id'")
                    if 'title' not in option:
                        errors.append(f"Step {i}, option {j}: missing required field 'title'")

    return errors
