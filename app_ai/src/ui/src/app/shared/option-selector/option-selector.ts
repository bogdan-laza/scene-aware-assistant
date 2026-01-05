import { Component, computed, contentChildren, input, signal } from '@angular/core';
import { OptionComponent } from '../option/option';

@Component({
  selector: 'app-select',
  template: `
    <div class="trigger" (click)="toggleDropdown()">
      {{ selectedLabel() || 'Select an option' }}
    </div>

    <div class="dropdown" [style.display]="isOpen() ? 'block' : 'none'">
      <ng-content></ng-content>
    </div>
  `,
  standalone: false,
})

export class SelectComponent {
  private selectedValue = signal<string | null>(null);
  isOpen = signal(false);

  options = contentChildren(OptionComponent);

  toggleDropdown() {
    this.isOpen.set(!this.isOpen());
  }

  // 4. Create a helper to set value (to be called by options or via effect)
  selectValue(val: string) {
    this.selectedValue.set(val);
    this.isOpen.set(false);
  }

  // 5. Computed now works because options are always "alive"
  selectedLabel = computed(() => {
    const opts = this.options();
    const selected = opts.find(opt => opt.value() === this.selectedValue());
    return selected ? selected.label() : null;
  });
}
