# frozen_string_literal: true

module ManyfoldMyminifactory
  # Preserve the creator card and its native actions on hosts without the hook.
  module CreatorMenu
    CONTEXT = :@manyfold_myminifactory_creator_menu

    def self.install!
      ActionView::Template.prepend(TemplateContext) unless ActionView::Template < TemplateContext
      ComponentsHelper.prepend(MenuItems) unless ComponentsHelper < MenuItems
    end

    # Other provider plugins may already supply this compatibility hook. Their
    # helper renders every registered provider, so only one shim should render.
    # Check at render time because the other plugin can initialize after us.
    def self.external_hook?
      ComponentsHelper.ancestors.any? do |helper|
        name = helper.name
        next false if helper == MenuItems || !name&.end_with?("::CreatorMenu::MenuItems")

        template_name = name.delete_suffix("::MenuItems") + "::TemplateContext"
        ActionView::Template.ancestors.any? { |template| template.name == template_name }
      end
    end

    module TemplateContext
      def render(view, locals, *arguments, **options, &block)
        return super if CreatorMenu.external_hook?

        previous = view.instance_variable_get(CONTEXT)
        creator = if virtual_path == "creators/_creator" &&
            !source.match?(/components_for\s*(?:\(\s*)?:creator_menu\b/)
          locals[:creator]
        end
        view.instance_variable_set(CONTEXT, creator)
        begin
          super
        ensure
          view.instance_variable_set(CONTEXT, previous)
        end
      end
    end

    module MenuItems
      def BurgerMenu(**arguments, &block)
        return super if CreatorMenu.external_hook?

        creator = instance_variable_get(CONTEXT)
        components = PluginManager.components_for(:creator_menu)
        return super unless creator && block && components.any?

        super(**arguments) do |*block_arguments|
          original_items = capture(*block_arguments, &block)
          additional_items = components.filter_map do |component|
            content = render(component.new(creator: creator))
            content_tag(:li, content, role: "presentation") if content.present?
          end
          safe_join([original_items, *additional_items])
        end
      end
    end
  end
end
